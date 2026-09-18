from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.exceptions import AirflowSkipException
from datetime import datetime, timezone
import os
import json
import subprocess
from pathlib import Path


def get_run_time(ci_folder):
    run_results = ci_folder / "run_results.json"
    if not run_results.exists():
        return datetime.min.replace(tzinfo=timezone.utc)

    try:
        with open(run_results) as f:
            data = json.load(f)

        return datetime.fromisoformat(
            data["metadata"]["generated_at"].replace("Z", "+00:00")
        )
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)


def build_quarantine_exclude_list(
    dbt_state_root: str,
    env: str,
    changed_models_file: str,
    **context
):
    dag_run = context.get("dag_run")
    git_sha = dag_run.conf.get("git_sha", "manual") if dag_run else "manual"

    ci_root = Path(dbt_state_root) / env / "ci"
    ci_state = ci_root / git_sha
    ci_state.mkdir(parents=True, exist_ok=True)

    exclude_file = ci_state / "exclude_models.txt"
    exclude_file.write_text("")

    # Load changed models
    if os.path.exists(changed_models_file):
        with open(changed_models_file) as f:
            changed_models = set(m.strip() for m in f.read().split())
    else:
        changed_models = set()

    model_status = {}

    # Loop over previous CI runs
    for ci_folder in sorted(ci_root.iterdir(), key=get_run_time, reverse=True):
        run_results = ci_folder / "run_results.json"
        if not run_results.exists():
            continue

        with open(run_results) as f:
            data = json.load(f)

        for r in data.get("results", []):
            model = r["unique_id"].split(".")[-1]
            status = r["status"]
            model_f = r["unique_id"]

            # Skip models changed in this commit
            if model_f in changed_models:
                continue

            # Only take latest result (first seen in reverse order)
            if model not in model_status:
                model_status[model] = status

    # Write quarantined models
    with open(exclude_file, "a") as f:
        for model, status in model_status.items():
            if status == "error":
                f.write(f"model:{model}\n")

    print("Excluded models:")
    print(exclude_file.read_text() or "None")


def drop_deleted_bq_models(
    dbt_project_path: str,
    deleted_models_file: str,
    env: str,
    **context
):
    # Skip if file doesn't exist
    if not os.path.exists(deleted_models_file):
        raise AirflowSkipException("No deleted_models.txt found — nothing to drop.")
 
    # Read and clean entries
    with open(deleted_models_file) as f:
        deleted = [m.strip() for m in f.readlines() if m.strip()]
 
    # Skip if file is empty
    if not deleted:
        raise AirflowSkipException("deleted_models.txt is empty — nothing to drop.")
 
    # Validate format — each entry must be model_name|dataset
    for entry in deleted:
        if '|' not in entry:
            raise Exception(f"Invalid entry in deleted_models.txt: '{entry}'. Expected format: model_name|dataset")
 
    print(f"Models to drop from BQ: {deleted}")
 
    cmd = [
        "dbt", "run-operation", "drop_models",
        "--args", json.dumps({"models": deleted}),
        "--target", env
    ]
 
    print(f"Running: {' '.join(cmd)}")
 
    result = subprocess.run(cmd, cwd=dbt_project_path, capture_output=False)
 
    if result.returncode != 0:
        raise Exception(f"dbt run-operation drop_models failed with exit code {result.returncode}")
 
    print("BQ drop completed successfully.")


ENV = os.environ.get("AIRFLOW_ENVIRONMENT")
GIT_SHA = "{{ dag_run.conf['git_sha'] if dag_run else 'manual' }}"
DBT_PROJECT_PATH = "/home/airflow/gcsfuse/data/code/hub_gld_eu_dbt_views"
DBT_STATE_ROOT = "/home/airflow/gcsfuse/data/dbt_state"
BASELINE_STATE = f"{DBT_STATE_ROOT}/{ENV}/baseline"
CI_STATE = f"{DBT_STATE_ROOT}/{ENV}/ci/{GIT_SHA}"

# Produced by GitHub Actions and uploaded to GCS
CHANGED_MODELS_FILE = "/home/airflow/gcsfuse/data/code/changed_models.txt"
DELETED_MODELS_FILE = "/home/airflow/gcsfuse/data/code/deleted_models.txt"

DEFAULT_ARGS = {
    "owner": "DataFabric-EU-Gold-Layer-Team",
    "start_date": datetime(2026, 1, 27),
    "retries": 0
}

with DAG(
    dag_id="hub_gld_eu_dbt_views_deployment",
    schedule_interval=None,
    catchup=False,
    default_args=DEFAULT_ARGS,
    tags=["dbt", "hub-gld-eu", ENV]
) as dag:

    # 1️⃣ Prepare folders
    prepare_dirs = BashOperator(
        task_id="prepare_dirs",
        bash_command=f"mkdir -p {BASELINE_STATE} {CI_STATE}"
    )

    # 2️⃣ dbt deps
    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"cd {DBT_PROJECT_PATH} && dbt deps"
    )

    # 3️⃣ dbt debug
    dbt_debug = BashOperator(
        task_id="dbt_debug",
        bash_command=f"cd {DBT_PROJECT_PATH} && dbt debug --target {ENV}"
    )

    # 4️⃣ Drop deleted models from BQ (skips if nothing to delete)
    drop_deleted_models = PythonOperator(
        task_id="drop_deleted_models",
        python_callable=drop_deleted_bq_models,
        op_kwargs={
            "dbt_project_path": DBT_PROJECT_PATH,
            "deleted_models_file": DELETED_MODELS_FILE,
            "env": ENV,
        }
    )

    # 5️⃣ Build quarantine exclude list
    quarantine_failed = PythonOperator(
        task_id="quarantine_failed",
        trigger_rule="none_failed",
        python_callable=build_quarantine_exclude_list,
        op_kwargs={
            "dbt_state_root": DBT_STATE_ROOT,
            "env": ENV,
            "changed_models_file": CHANGED_MODELS_FILE
        }
    )

    # 6️⃣ dbt build
    dbt_build = BashOperator(
        task_id="dbt_build",
        bash_command=f"""
    set -e
    cd {DBT_PROJECT_PATH}

    # Guard: if no changed models and no baseline, nothing to build
    if [ ! -s "{CHANGED_MODELS_FILE}" ] && [ ! -f "{BASELINE_STATE}/manifest.json" ]; then
        echo "No changed models and no baseline found — skipping dbt build"
        exit 0
    fi

    # Convert newlines to spaces
    EXCLUDE=$(cat {CI_STATE}/exclude_models.txt 2>/dev/null | sed 's/^model://' | tr '\\n' ' ' || echo "")

    # Create an isolated dynamic directory for this specific Airflow task run
    TASK_TMP="/tmp/dbt_run_{{{{ task_instance_key_str }}}}"
    mkdir -p "$TASK_TMP"

    # Set environment variables to force target files to local scratch space
    export DBT_TARGET_PATH="$TASK_TMP"

    # Always copy back whatever artifacts exist, even on failure, then propagate the real exit code
    cleanup() {{
        EXIT_CODE=$?
        [ -f "$TASK_TMP/manifest.json" ] && cp "$TASK_TMP/manifest.json" {DBT_PROJECT_PATH}/target/manifest.json
        [ -f "$TASK_TMP/run_results.json" ] && cp "$TASK_TMP/run_results.json" {DBT_PROJECT_PATH}/target/run_results.json
        rm -rf "$TASK_TMP"
        exit $EXIT_CODE
    }}
    trap cleanup EXIT

    DBT_GLOBAL="--no-partial-parse --log-path $TASK_TMP"

    if [ -f "{BASELINE_STATE}/manifest.json" ]; then
        echo "Incremental build using baseline, excluding only unchanged failing models"
        if [ -n "$EXCLUDE" ]; then
            echo "Running: dbt $DBT_GLOBAL run --select state:modified+ --exclude $EXCLUDE --state {BASELINE_STATE} --target {ENV}"
            dbt $DBT_GLOBAL run --select state:modified+ --exclude $EXCLUDE --state {BASELINE_STATE} --target {ENV}
        else
            echo "Running: dbt $DBT_GLOBAL run --select state:modified+ --state {BASELINE_STATE} --target {ENV}"
            dbt $DBT_GLOBAL run --select state:modified+ --state {BASELINE_STATE} --target {ENV}
        fi
    else
        echo "No baseline → running all models in this commit, excluding unchanged failing models"
        if [ -n "$EXCLUDE" ]; then
            echo "Running: dbt $DBT_GLOBAL run --exclude $EXCLUDE --target {ENV}"
            dbt $DBT_GLOBAL run --exclude $EXCLUDE --target {ENV}
        else
            echo "Running: dbt $DBT_GLOBAL run --target {ENV}"
            dbt $DBT_GLOBAL run --target {ENV}
        fi
    fi
    """
    )

    # 7️⃣ Save CI state (always, even if some models fail)
    save_ci_state = BashOperator(
        task_id="save_ci_state",
        trigger_rule="all_done",
        bash_command=f"cp {DBT_PROJECT_PATH}/target/manifest.json {CI_STATE}/ && cp {DBT_PROJECT_PATH}/target/run_results.json {CI_STATE}/"
    )

    # 8️⃣ Promote baseline only if DAG succeeded
    promote_baseline = BashOperator(
        task_id="promote_baseline",
        trigger_rule="all_success",
        bash_command=f"cp {CI_STATE}/manifest.json {BASELINE_STATE}/ && cp {CI_STATE}/run_results.json {BASELINE_STATE}/"
    )

    # DAG chain
    prepare_dirs >> dbt_deps >> dbt_debug  >> drop_deleted_models >> quarantine_failed >> dbt_build >> save_ci_state

    [dbt_build, save_ci_state] >> promote_baseline
