#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Run local coverage pipeline similar to .github/workflows/coverage.yml.

Usage:
  scripts/run_coverage_local.sh [options]

Options:
  --profile <cpu|cpu_gpu|cpu_npu|cpu_npu_gpu>  Hardware profile (default: cpu)
  --workspace <path>                            Workspace root (default: current directory)
  --build-type <Release|Debug|...>             CMake build type (default: Release)
  --install-deps                                Run apt/pip dependency installation like CI
  --skip-cpp                                    Skip C++ test execution
  --skip-python                                 Skip Python test execution
  --skip-js                                     Skip JS test execution
  --parallel-jobs <N>                           Build parallelism (default: 64)
  --pytest-workers <N>                          Pytest xdist workers (default: 64)
  --js-concurrency <N>                          Node test concurrency (default: 64)
  --cxx-binary-parallelism <N>                  Max concurrent C++ binaries (default: 16)
  --gtest-parallel-workers <N>                  gtest-parallel workers per binary (default: 4)
  -h, --help                                    Show this help
EOF
}

log() { printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
err() { printf '\n[ERROR] %s\n' "$*" >&2; }

TEST_PROFILE="cpu"
WORKSPACE="$(pwd)"
CMAKE_BUILD_TYPE="Release"
INSTALL_DEPS=0
SKIP_CPP=0
SKIP_PY=0
SKIP_JS=0
PARALLEL_JOBS="${PARALLEL_JOBS:-64}"
PYTEST_XDIST_WORKERS="${PYTEST_XDIST_WORKERS:-64}"
JS_TEST_CONCURRENCY="${JS_TEST_CONCURRENCY:-64}"
CXX_TEST_BINARY_PARALLELISM="${CXX_TEST_BINARY_PARALLELISM:-16}"
GTEST_PARALLEL_WORKERS="${GTEST_PARALLEL_WORKERS:-4}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) TEST_PROFILE="${2:?missing value}"; shift 2 ;;
    --workspace) WORKSPACE="${2:?missing value}"; shift 2 ;;
    --build-type) CMAKE_BUILD_TYPE="${2:?missing value}"; shift 2 ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --skip-cpp) SKIP_CPP=1; shift ;;
    --skip-python) SKIP_PY=1; shift ;;
    --skip-js) SKIP_JS=1; shift ;;
    --parallel-jobs) PARALLEL_JOBS="${2:?missing value}"; shift 2 ;;
    --pytest-workers) PYTEST_XDIST_WORKERS="${2:?missing value}"; shift 2 ;;
    --js-concurrency) JS_TEST_CONCURRENCY="${2:?missing value}"; shift 2 ;;
    --cxx-binary-parallelism) CXX_TEST_BINARY_PARALLELISM="${2:?missing value}"; shift 2 ;;
    --gtest-parallel-workers) GTEST_PARALLEL_WORKERS="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

case "${TEST_PROFILE}" in
  cpu|cpu_gpu|cpu_npu|cpu_npu_gpu) ;;
  *) err "Invalid profile: ${TEST_PROFILE}"; exit 2 ;;
esac

cd "${WORKSPACE}"
WORKSPACE="$(pwd)"

BUILD_DIR="${WORKSPACE}/build"
BUILD_JS_DIR="${WORKSPACE}/build_js"
INSTALL_DIR="${WORKSPACE}/install_pkg"
BIN_DIR="${WORKSPACE}/bin/intel64/${CMAKE_BUILD_TYPE}"
MODEL_PATH="${WORKSPACE}/src/core/tests/models/ir/add_abc.xml"
SUMMARY_FILE="${WORKSPACE}/coverage-local-summary.md"
GTEST_PARALLEL="${WORKSPACE}/gtest_parallel.py"
REPORT_DIR="${WORKSPACE}/coverage-report"

RUN_GPU_TESTS="false"
RUN_NPU_TESTS="false"
if [[ "${TEST_PROFILE}" == "cpu_gpu" || "${TEST_PROFILE}" == "cpu_npu_gpu" ]]; then
  RUN_GPU_TESTS="true"
fi
if [[ "${TEST_PROFILE}" == "cpu_npu" || "${TEST_PROFILE}" == "cpu_npu_gpu" ]]; then
  RUN_NPU_TESTS="true"
fi

GPU_FLAGS="-DENABLE_INTEL_GPU=OFF -DENABLE_ONEDNN_FOR_GPU=OFF"
NPU_FLAGS="-DENABLE_INTEL_NPU=OFF"
if [[ "${RUN_GPU_TESTS}" == "true" ]]; then
  GPU_FLAGS="-DENABLE_INTEL_GPU=ON -DENABLE_ONEDNN_FOR_GPU=ON"
fi
if [[ "${RUN_NPU_TESTS}" == "true" ]]; then
  NPU_FLAGS="-DENABLE_INTEL_NPU=ON"
fi

CXX_TESTS_TOTAL=0
CXX_TESTS_PASSED=0
CXX_TESTS_FAILED=0
CXX_TESTS_SKIPPED=0
PY_TESTS_TOTAL=0
PY_TESTS_PASSED=0
PY_TESTS_FAILED=0
PY_TESTS_SKIPPED=0
JS_TESTS_TOTAL=0
JS_TESTS_PASSED=0
JS_TESTS_FAILED=0
JS_TESTS_SKIPPED=0

: > "${SUMMARY_FILE}"

if [[ "${INSTALL_DEPS}" -eq 1 ]]; then
  log "Installing dependencies"
  SUDO=""
  if [[ $EUID -ne 0 ]]; then SUDO="sudo"; fi
  ${SUDO} apt --assume-yes update
  ${SUDO} -E "${WORKSPACE}/install_build_dependencies.sh"
  ${SUDO} apt --assume-yes install lcov wget pigz xvfb clang-14 libclang-14-dev clinfo ca-certificates
  python3 -m pip install --upgrade pip
  python3 -m pip install pytest pytest-cov pytest-xdist[psutil]
  python3 -m pip install -r "${WORKSPACE}/src/bindings/python/wheel/requirements-dev.txt"
  python3 -m pip install -r "${WORKSPACE}/src/frontends/paddle/tests/requirements.txt"
  python3 -m pip install -r "${WORKSPACE}/src/frontends/onnx/tests/requirements.txt"
  python3 -m pip install -r "${WORKSPACE}/src/frontends/tensorflow/tests/requirements.txt"
  python3 -m pip install -r "${WORKSPACE}/src/frontends/tensorflow_lite/tests/requirements.txt"
fi

log "Configuring build"
cmake -S "${WORKSPACE}" -B "${BUILD_DIR}" \
  -GNinja \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DENABLE_PYTHON=ON \
  -DENABLE_JS=ON \
  -DENABLE_TESTS=ON \
  -DENABLE_FUNCTIONAL_TESTS=ON \
  -DENABLE_OV_ONNX_FRONTEND=ON \
  -DENABLE_OV_PADDLE_FRONTEND=ON \
  -DENABLE_OV_TF_FRONTEND=ON \
  -DENABLE_OV_TF_LITE_FRONTEND=ON \
  -DENABLE_STRICT_DEPENDENCIES=OFF \
  -DENABLE_COVERAGE=ON \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_LINKER_LAUNCHER=ccache \
  -DCMAKE_CXX_LINKER_LAUNCHER=ccache \
  -DENABLE_SYSTEM_SNAPPY=ON \
  ${GPU_FLAGS} \
  ${NPU_FLAGS}

log "Building OpenVINO"
cmake --build "${BUILD_DIR}" --parallel "${PARALLEL_JOBS}" --config "${CMAKE_BUILD_TYPE}"

log "Installing wheel/runtime/tests"
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_DIR}" --component python_wheels --config "${CMAKE_BUILD_TYPE}"
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_DIR}" --config "${CMAKE_BUILD_TYPE}"
cmake --install "${BUILD_DIR}" --prefix "${INSTALL_DIR}" --component tests --config "${CMAKE_BUILD_TYPE}"

log "Building/installing JS runtime"
cmake -S "${WORKSPACE}" -B "${BUILD_JS_DIR}" \
  -GNinja \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
  -DCPACK_GENERATOR=NPM \
  -DENABLE_SYSTEM_TBB=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_SAMPLES=OFF \
  -DENABLE_WHEEL=OFF \
  -DENABLE_PYTHON=OFF \
  -DENABLE_INTEL_GPU=OFF \
  -DENABLE_JS=ON \
  -DENABLE_COVERAGE=ON \
  -DCMAKE_INSTALL_PREFIX="${WORKSPACE}/src/bindings/js/node/bin"
cmake --build "${BUILD_JS_DIR}" --parallel "${PARALLEL_JOBS}" --config "${CMAKE_BUILD_TYPE}"
cmake --install "${BUILD_JS_DIR}" --prefix "${WORKSPACE}/src/bindings/js/node/bin" --config "${CMAKE_BUILD_TYPE}"

log "Installing OpenVINO wheel"
WHEEL_PATH="$(ls -1 "${INSTALL_DIR}"/wheels/openvino-*.whl | head -n 1 || true)"
if [[ -z "${WHEEL_PATH}" ]]; then
  err "OpenVINO wheel not found in ${INSTALL_DIR}/wheels"
  exit 1
fi
python3 -m pip install --force-reinstall "${WHEEL_PATH}"

log "Downloading gtest-parallel"
wget -q https://raw.githubusercontent.com/google/gtest-parallel/master/gtest_parallel.py -O "${GTEST_PARALLEL}"

if [[ "${SKIP_CPP}" -eq 0 ]]; then
  log "Running selected C++ tests"
  set +e
  FAILED_FILE="$(mktemp)"
  SKIPPED_FILE="$(mktemp)"
  EXECUTED_FILE="$(mktemp)"

  GCOV_PREFIX_STRIP_VALUE="$(awk -F/ '{print NF-1}' <<< "${BUILD_DIR}")"
  GCOV_TASK_ROOT="${BUILD_DIR}/gcov"
  find "${BUILD_DIR}" -name '*.gcda' -delete || true
  rm -rf "${GCOV_TASK_ROOT}"
  mkdir -p "${GCOV_TASK_ROOT}"

  export OMP_NUM_THREADS=1
  export MKL_NUM_THREADS=1
  export OPENBLAS_NUM_THREADS=1
  export TBB_NUM_THREADS=1

  enqueue_task() {
    local test_name="$1"
    local binary_name="$2"
    local mode="$3"
    local gtest_filter="${4:-}"
    local extra_env="${5:-}"

    local exe_path="${BIN_DIR}/${binary_name}"
    if [[ ! -x "${exe_path}" ]]; then
      echo "${test_name} (missing binary: ${binary_name})" >> "${SKIPPED_FILE}"
      return 0
    fi

    while [[ "$(jobs -pr | wc -l)" -ge "${CXX_TEST_BINARY_PARALLELISM}" ]]; do
      wait -n
    done

    (
      echo "${test_name}" >> "${EXECUTED_FILE}"
      local task_slug
      task_slug="$(echo "${test_name}" | tr -cs '[:alnum:]' '_' | sed 's/^_//; s/_$//')"
      local task_cov_dir="${GCOV_TASK_ROOT}/${task_slug}-${BASHPID}"
      mkdir -p "${task_cov_dir}"
      local -a env_cmd=("env" "GCOV_PREFIX=${task_cov_dir}" "GCOV_PREFIX_STRIP=${GCOV_PREFIX_STRIP_VALUE}")
      if [[ -n "${extra_env}" ]]; then
        local -a extra_env_parts
        read -r -a extra_env_parts <<< "${extra_env}"
        env_cmd+=("${extra_env_parts[@]}")
      fi

      if [[ "${mode}" == "gtest_parallel" ]]; then
        if [[ -n "${gtest_filter}" ]]; then
          "${env_cmd[@]}" python3 "${GTEST_PARALLEL}" "${exe_path}" --workers="${GTEST_PARALLEL_WORKERS}" -- --gtest_filter="${gtest_filter}"
        else
          "${env_cmd[@]}" python3 "${GTEST_PARALLEL}" "${exe_path}" --workers="${GTEST_PARALLEL_WORKERS}"
        fi
      elif [[ "${mode}" == "gtest_single" ]]; then
        if [[ -n "${gtest_filter}" ]]; then
          "${env_cmd[@]}" "${exe_path}" --gtest_filter="${gtest_filter}"
        else
          "${env_cmd[@]}" "${exe_path}"
        fi
      else
        if [[ -n "${gtest_filter}" ]]; then
          local -a raw_args
          read -r -a raw_args <<< "${gtest_filter}"
          "${env_cmd[@]}" "${exe_path}" "${raw_args[@]}"
        else
          "${env_cmd[@]}" "${exe_path}"
        fi
      fi
      local rc=$?
      if [[ ${rc} -ne 0 ]]; then
        echo "${test_name} (exit ${rc})" >> "${FAILED_FILE}"
      fi
    ) &
  }

  if [[ "${RUN_NPU_TESTS}" != "true" ]]; then
    echo "ov_npu_func_tests (NPU profile is OFF)" >> "${SKIPPED_FILE}"
    echo "ov_npu_unit_tests (NPU profile is OFF)" >> "${SKIPPED_FILE}"
  fi
  echo "ov_nvidia_func_tests (unsupported in coverage workflow)" >> "${SKIPPED_FILE}"
  if [[ "${RUN_GPU_TESTS}" != "true" ]]; then
    echo "ov_gpu_unit_tests (GPU switch is OFF, CPU-only mode)" >> "${SKIPPED_FILE}"
    echo "ov_gpu_func_tests (GPU switch is OFF, CPU-only mode)" >> "${SKIPPED_FILE}"
  fi

  enqueue_task "ov_api_conformance_tests" "ov_api_conformance_tests" "gtest_parallel" "*mandatory*"
  enqueue_task "ov_auto_batch_func_tests" "ov_auto_batch_func_tests" "gtest_parallel" "*smoke*"
  enqueue_task "ov_auto_batch_unit_tests" "ov_auto_batch_unit_tests" "gtest_parallel"
  enqueue_task "ov_auto_func_tests" "ov_auto_func_tests" "gtest_parallel" "*smoke*"
  enqueue_task "ov_auto_unit_tests" "ov_auto_unit_tests" "gtest_parallel"
  enqueue_task "ov_capi_test" "ov_capi_test" "gtest_parallel"
  enqueue_task "ov_conditional_compilation_tests" "ov_conditional_compilation_tests" "gtest_parallel"
  if [[ "${RUN_GPU_TESTS}" == "true" ]]; then
    enqueue_task "ov_core_unit_tests" "ov_core_unit_tests" "gtest_parallel"
  else
    enqueue_task "ov_core_unit_tests" "ov_core_unit_tests" "gtest_parallel" "-*IE_GPU*"
  fi
  enqueue_task "ov_cpu_func_tests" "ov_cpu_func_tests" "gtest_single" "*smoke*"
  enqueue_task "ov_cpu_unit_tests" "ov_cpu_unit_tests" "gtest_parallel"
  enqueue_task "ov_cpu_unit_tests_vectorized" "ov_cpu_unit_tests_vectorized" "gtest_parallel"
  enqueue_task "ov_hetero_func_tests" "ov_hetero_func_tests" "gtest_parallel" "*smoke*:-nightly*"
  enqueue_task "ov_hetero_unit_tests" "ov_hetero_unit_tests" "gtest_parallel"
  enqueue_task "ov_inference_functional_tests" "ov_inference_functional_tests" "gtest_single"
  enqueue_task "ov_inference_unit_tests" "ov_inference_unit_tests" "gtest_parallel"
  enqueue_task "ov_ir_frontend_tests" "ov_ir_frontend_tests" "gtest_parallel"
  enqueue_task "ov_lp_transformations_tests" "ov_lp_transformations_tests" "gtest_parallel"
  if [[ "${RUN_GPU_TESTS}" == "true" ]]; then
    enqueue_task "ov_onnx_frontend_tests" "ov_onnx_frontend_tests" "gtest_single"
    enqueue_task "ov_onnx_frontend_tests (ONNX_ITERATOR=0)" "ov_onnx_frontend_tests" "gtest_single" "" "ONNX_ITERATOR=0"
  else
    enqueue_task "ov_onnx_frontend_tests" "ov_onnx_frontend_tests" "gtest_single" "-*IE_GPU*"
    enqueue_task "ov_onnx_frontend_tests (ONNX_ITERATOR=0)" "ov_onnx_frontend_tests" "gtest_single" "-*IE_GPU*" "ONNX_ITERATOR=0"
  fi
  enqueue_task "ov_op_conformance_tests" "ov_op_conformance_tests" "raw" "--device=TEMPLATE --gtest_filter=*OpImpl*"
  enqueue_task "ov_proxy_plugin_tests" "ov_proxy_plugin_tests" "gtest_parallel"
  enqueue_task "ov_snippets_func_tests" "ov_snippets_func_tests" "gtest_parallel"
  enqueue_task "ov_subgraphs_dumper_tests" "ov_subgraphs_dumper_tests" "gtest_parallel"
  enqueue_task "ov_template_func_tests" "ov_template_func_tests" "gtest_parallel" "*smoke*"
  enqueue_task "ov_tensorflow_common_tests" "ov_tensorflow_common_tests" "gtest_parallel"
  if [[ "${RUN_GPU_TESTS}" == "true" ]]; then
    enqueue_task "ov_tensorflow_frontend_tests" "ov_tensorflow_frontend_tests" "gtest_single"
  else
    enqueue_task "ov_tensorflow_frontend_tests" "ov_tensorflow_frontend_tests" "gtest_single" "-*IE_GPU*"
  fi
  enqueue_task "ov_tensorflow_lite_frontend_tests" "ov_tensorflow_lite_frontend_tests" "gtest_parallel"
  enqueue_task "ov_transformations_tests" "ov_transformations_tests" "gtest_parallel"
  enqueue_task "ov_util_tests" "ov_util_tests" "gtest_parallel"
  enqueue_task "paddle_tests" "paddle_tests" "gtest_parallel"
  if [[ "${RUN_NPU_TESTS}" == "true" ]]; then
    enqueue_task "ov_npu_unit_tests" "ov_npu_unit_tests" "gtest_parallel"
    enqueue_task "ov_npu_func_tests" "ov_npu_func_tests" "gtest_single" "*smoke*"
  fi
  if [[ "${RUN_GPU_TESTS}" == "true" ]]; then
    enqueue_task "ov_gpu_unit_tests" "ov_gpu_unit_tests" "gtest_parallel"
    enqueue_task "ov_gpu_func_tests" "ov_gpu_func_tests" "gtest_single" "*smoke*"
  fi
  enqueue_task "test_inference_async" "test_inference_async" "raw" "${MODEL_PATH} CPU"
  enqueue_task "test_inference_sync" "test_inference_sync" "raw" "${MODEL_PATH} CPU"

  wait
  mapfile -t FAILED_TESTS < "${FAILED_FILE}" || true
  mapfile -t SKIPPED_TESTS < "${SKIPPED_FILE}" || true
  mapfile -t EXECUTED_TESTS < "${EXECUTED_FILE}" || true
  rm -f "${FAILED_FILE}" "${SKIPPED_FILE}" "${EXECUTED_FILE}"

  CXX_TESTS_PASSED=$(( ${#EXECUTED_TESTS[@]} - ${#FAILED_TESTS[@]} ))
  CXX_TESTS_FAILED=${#FAILED_TESTS[@]}
  CXX_TESTS_SKIPPED=${#SKIPPED_TESTS[@]}
  CXX_TESTS_TOTAL=$(( ${#EXECUTED_TESTS[@]} + CXX_TESTS_SKIPPED ))
  set -e
fi

if [[ "${SKIP_PY}" -eq 0 ]]; then
  log "Running Python tests"
  set +e
  TESTS_DIR="${INSTALL_DIR}/tests"
  SRC_PY_TESTS_DIR="${WORKSPACE}/src/bindings/python/tests"
  ONNX_PY_TESTS_DIR="${WORKSPACE}/src/frontends/onnx/tests/tests_python"
  PY_COV_CONFIG="${WORKSPACE}/.python_coverage_ci.rc"
  FAILED_PY_TESTS=()
  SKIPPED_PY_TESTS=()
  PY_EXECUTED=0

  python3 -m pip install -r "${TESTS_DIR}/bindings/python/requirements_test.txt"
  python3 -m pip install -r "${TESTS_DIR}/layer_tests/requirements.txt"
  python3 -m pip install -r "${TESTS_DIR}/requirements_onnx"

  export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
  export PYTHONPATH="${TESTS_DIR}/python:${PYTHONPATH:-}"

  cat > "${PY_COV_CONFIG}" <<'PYCOV'
[run]
omit =
    */tests/*
    */thirdparty/*
    */docs/*
    */samples/*
    */tools/*
    */src/bindings/js/node/tests/*
    */src/bindings/python/tests/*
    *.pb.cc
    *.pb.h
PYCOV

  coverage erase
  run_pytest() {
    local name="$1"; shift
    PY_EXECUTED=$((PY_EXECUTED + 1))
    python3 -m pytest -ra --durations=50 "$@"
    local rc=$?
    [[ ${rc} -ne 0 ]] && FAILED_PY_TESTS+=("${name} (exit ${rc})")
  }
  run_pytest_if_dir() {
    local name="$1"; local dir="$2"; shift 2
    if [[ -d "${dir}" ]]; then
      run_pytest "${name}" -sv "${dir}" -n "${PYTEST_XDIST_WORKERS}" "$@"
    else
      SKIPPED_PY_TESTS+=("${name} (missing path)")
    fi
  }
  run_python_cmd() {
    local name="$1"; shift
    PY_EXECUTED=$((PY_EXECUTED + 1))
    "$@"
    local rc=$?
    [[ ${rc} -ne 0 ]] && FAILED_PY_TESTS+=("${name} (exit ${rc})")
  }

  run_pytest "pyopenvino" -sv "${TESTS_DIR}/pyopenvino" -n "${PYTEST_XDIST_WORKERS}" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append --ignore="${TESTS_DIR}/pyopenvino/tests/test_utils/test_utils.py"
  run_pytest "onnx_python" -sv "${TESTS_DIR}/onnx" -n "${PYTEST_XDIST_WORKERS}" -k "not cuda" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append --ignore="${TESTS_DIR}/onnx/test_python/test_zoo_models.py"
  run_pytest "ovc_unit" -sv "${TESTS_DIR}/ovc/unit_tests" -n "${PYTEST_XDIST_WORKERS}" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "py_frontend" "${TESTS_DIR}/layer_tests/py_frontend_tests" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "tensorflow_lite_layers" "${TESTS_DIR}/layer_tests/tensorflow_lite_tests" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "tensorflow_layers" "${TESTS_DIR}/layer_tests/tensorflow_tests" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "onnx_layers" "${TESTS_DIR}/layer_tests/onnx_tests" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "pytorch_layers" "${TESTS_DIR}/layer_tests/pytorch_tests" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  TEST_DEVICE=CPU TEST_PRECISION=FP16 run_pytest_if_dir "paddle_layers" "${TESTS_DIR}/layer_tests/paddle_tests" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_pytest_if_dir "src_py_runtime" "${SRC_PY_TESTS_DIR}/test_runtime" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_pytest_if_dir "src_py_graph" "${SRC_PY_TESTS_DIR}/test_graph" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_pytest_if_dir "src_py_transformations" "${SRC_PY_TESTS_DIR}/test_transformations" -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_pytest_if_dir "src_onnx_frontend_python" "${ONNX_PY_TESTS_DIR}" -k "not gpu and not cuda and not npu and not zoo" --ignore="${ONNX_PY_TESTS_DIR}/test_zoo_models.py" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_pytest_if_dir "src_py_runtime_strict" "${SRC_PY_TESTS_DIR}/test_runtime" -q --maxfail=1 -k "not gpu and not cuda and not npu" --cov=openvino --cov-config="${PY_COV_CONFIG}" --cov-append
  run_python_cmd "ovc_cli_help" python3 -m openvino.tools.ovc --help

  coverage xml -o "${WORKSPACE}/python-coverage.xml"
  PY_TESTS_FAILED=${#FAILED_PY_TESTS[@]}
  PY_TESTS_SKIPPED=${#SKIPPED_PY_TESTS[@]}
  PY_TESTS_PASSED=$((PY_EXECUTED - PY_TESTS_FAILED))
  PY_TESTS_TOTAL=$((PY_EXECUTED + PY_TESTS_SKIPPED))
  set -e
fi

if [[ "${SKIP_JS}" -eq 0 ]]; then
  log "Running JS tests"
  set +e
  JS_DIR="${WORKSPACE}/src/bindings/js/node"
  JS_EXECUTED=0
  FAILED_JS_TESTS=()
  cd "${JS_DIR}"
  npm i
  npm i --no-save c8
  run_js_cmd() {
    local name="$1"; shift
    JS_EXECUTED=$((JS_EXECUTED + 1))
    "$@"
    local rc=$?
    [[ ${rc} -ne 0 ]] && FAILED_JS_TESTS+=("${name} (exit ${rc})")
  }
  run_js_c8_unit() {
    local name="$1"; local clean="$2"; shift 2
    JS_EXECUTED=$((JS_EXECUTED + 1))
    npx c8 --reporter=lcov --reporter=text --report-dir "${WORKSPACE}/js-coverage" \
      --clean="${clean}" --exclude "tests/**" --exclude "thirdparty/**" \
      node --test --test-concurrency="${JS_TEST_CONCURRENCY}" "$@"
    local rc=$?
    [[ ${rc} -ne 0 ]] && FAILED_JS_TESTS+=("${name} (exit ${rc})")
  }
  run_js_cmd "npm run lint" npm run lint
  run_js_cmd "npm run tsc" npm run tsc
  run_js_cmd "npm run test_setup" npm run test_setup
  run_js_c8_unit "node unit group 1" true ./tests/unit/core.test.js ./tests/unit/model.test.js ./tests/unit/read_model.test.js ./tests/unit/basic.test.js
  run_js_c8_unit "node unit group 2" false ./tests/unit/compiled_model.test.js ./tests/unit/infer_request.test.js ./tests/unit/async_infer_queue.test.js
  run_js_c8_unit "node unit group 3" false ./tests/unit/tensor.test.js ./tests/unit/partial_shape.test.js ./tests/unit/pre_post_processor.test.js
  JS_EXECUTED=$((JS_EXECUTED + 1))
  Xvfb :99 &
  export DISPLAY=:99
  npx c8 --reporter=lcov --reporter=text --report-dir "${WORKSPACE}/js-coverage" \
    --clean=false --exclude "tests/**" --exclude "thirdparty/**" \
    npm run test:e2e --loglevel=silly
  rc=$?
  [[ ${rc} -ne 0 ]] && FAILED_JS_TESTS+=("npm run test:e2e (exit ${rc})")
  if [[ -f "${WORKSPACE}/js-coverage/lcov.info" ]]; then
    cp "${WORKSPACE}/js-coverage/lcov.info" "${WORKSPACE}/js-lcov.info"
  fi
  JS_TESTS_FAILED=${#FAILED_JS_TESTS[@]}
  JS_TESTS_SKIPPED=0
  JS_TESTS_PASSED=$((JS_EXECUTED - JS_TESTS_FAILED))
  JS_TESTS_TOTAL=${JS_EXECUTED}
  cd "${WORKSPACE}"
  set -e
fi

log "Generating C/C++ coverage report"
if ! lcov --capture \
  --directory "${BUILD_DIR}" \
  --directory "${BUILD_DIR}/gcov" \
  --build-directory "${BUILD_DIR}" \
  --base-directory "${WORKSPACE}" \
  --output-file "${WORKSPACE}/coverage.info" \
  --no-external \
  --rc geninfo_unexecuted_blocks=1 \
  --ignore-errors mismatch,negative,unused; then
  lcov --capture \
    --directory "${BUILD_DIR}" \
    --directory "${BUILD_DIR}/gcov" \
    --build-directory "${BUILD_DIR}" \
    --base-directory "${WORKSPACE}" \
    --output-file "${WORKSPACE}/coverage.info" \
    --no-external \
    --rc geninfo_unexecuted_blocks=1 \
    --ignore-errors mismatch,negative,unused,gcov
fi

lcov --remove "${WORKSPACE}/coverage.info" \
  --ignore-errors unused,mismatch \
  "${WORKSPACE}/*.pb.cc" \
  "${WORKSPACE}/*.pb.h" \
  "${WORKSPACE}/*/tests/*" \
  "${WORKSPACE}/tests/*" \
  "${WORKSPACE}/docs/*" \
  "${WORKSPACE}/samples/*" \
  "${WORKSPACE}/tools/*" \
  "${WORKSPACE}/src/bindings/js/node/tests/*" \
  "${WORKSPACE}/src/bindings/python/tests/*" \
  "${WORKSPACE}/thirdparty/*" \
  -o "${WORKSPACE}/coverage.info"

mkdir -p "${REPORT_DIR}"
genhtml "${WORKSPACE}/coverage.info" --output-directory "${REPORT_DIR}" --prefix "${WORKSPACE}" --synthesize-missing

log "Packaging report"
tar -czf "${WORKSPACE}/coverage-report.tgz" \
  -C "${WORKSPACE}" coverage-report coverage.info python-coverage.xml js-lcov.info 2>/dev/null || true

OVERALL_TOTAL=$((CXX_TESTS_TOTAL + PY_TESTS_TOTAL + JS_TESTS_TOTAL))
OVERALL_PASSED=$((CXX_TESTS_PASSED + PY_TESTS_PASSED + JS_TESTS_PASSED))
OVERALL_FAILED=$((CXX_TESTS_FAILED + PY_TESTS_FAILED + JS_TESTS_FAILED))
OVERALL_SKIPPED=$((CXX_TESTS_SKIPPED + PY_TESTS_SKIPPED + JS_TESTS_SKIPPED))
PASS_RATE="0.0"
if [[ "${OVERALL_TOTAL}" -gt 0 ]]; then
  PASS_RATE="$(awk "BEGIN {printf \"%.1f\", (${OVERALL_PASSED}*100)/${OVERALL_TOTAL}}")"
fi

cat > "${SUMMARY_FILE}" <<EOF
## Coverage Report Summary

Profile: \`${TEST_PROFILE}\`
Overall pass rate: \`${PASS_RATE}%\`

| Suite | Total | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| C++ | ${CXX_TESTS_TOTAL} | ${CXX_TESTS_PASSED} | ${CXX_TESTS_FAILED} | ${CXX_TESTS_SKIPPED} |
| Python | ${PY_TESTS_TOTAL} | ${PY_TESTS_PASSED} | ${PY_TESTS_FAILED} | ${PY_TESTS_SKIPPED} |
| JS | ${JS_TESTS_TOTAL} | ${JS_TESTS_PASSED} | ${JS_TESTS_FAILED} | ${JS_TESTS_SKIPPED} |

Artifacts:
- ${WORKSPACE}/coverage.info
- ${WORKSPACE}/python-coverage.xml
- ${WORKSPACE}/js-lcov.info
- ${WORKSPACE}/coverage-report/index.html
- ${WORKSPACE}/coverage-report.tgz
EOF

log "Done. Summary: ${SUMMARY_FILE}"
log "Open HTML report: ${REPORT_DIR}/index.html"
