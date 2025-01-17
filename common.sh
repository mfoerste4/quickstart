# Copyright 2021 NVIDIA Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

function detect_platform {
    if [[ -n "${PLATFORM+x}" ]]; then
        return
    elif command -v dnsdomainname &> /dev/null && [[ "$(dnsdomainname)" == *"summit"* ]]; then
        export PLATFORM=summit
    elif [[ "$(uname -n)" == *"daint"* ]]; then
        export PLATFORM=pizdaint
    elif [[ "$(uname -n)" == *"sapling2"* ]]; then
        export PLATFORM=sapling2
    elif [[ "$(uname -n)" == *"lassen"* ]]; then
        export PLATFORM=lassen
    else
        export PLATFORM=other
    fi
}

function set_build_vars {
    # Set base build variables according to target platform
    if [[ "$PLATFORM" == summit ]]; then
        export CONDUIT="${CONDUIT:-ibv}"
        export GPU_ARCH=volta
        # Compiling TBLIS, a dependency of cuNumeric on PowerPC requires
        # these defines to be set.
        export CXXFLAGS="${CXXFLAGS:-} -DNO_WARN_X86_INTRINSICS"
        export CFLAGS="${CFLAGS:-} -DNO_WARN_X86_INTRINSICS"
    elif [[ "$PLATFORM" == pizdaint ]]; then
        export CONDUIT="${CONDUIT:-aries}"
        export GPU_ARCH=pascal
    elif [[ "$PLATFORM" == sapling2 ]]; then
        export CONDUIT="${CONDUIT:-ibv}"
        export GPU_ARCH=pascal
    elif [[ "$PLATFORM" == lassen ]]; then
        export CONDUIT="${CONDUIT:-ibv}"
        export GPU_ARCH=volta
        # Compiling TBLIS, a dependency of cuNumeric on PowerPC requires
        # these defines to be set.
        export CXXFLAGS="${CXXFLAGS:-} -DNO_WARN_X86_INTRINSICS"
        export CFLAGS="${CFLAGS:-} -DNO_WARN_X86_INTRINSICS"
    elif [[ "$PLATFORM" == generic-* ]]; then
        export NETWORK="${NETWORK:-none}"
        export CONDUIT="${CONDUIT:-none}"
        export GPU_ARCH="${PLATFORM#generic-}"
    else
        if [[ -f /proc/self/cgroup ]] && grep -q docker /proc/self/cgroup; then
            echo "Error: Detected a docker build for an unknown target platform" 1>&2
            exit 1
        fi
        echo "Did not detect a supported cluster, assuming local-node build"
        if [[ -z "${NETWORK+x}" ]]; then
            if command -v mpirun &> /dev/null; then
                export NETWORK=gasnet1
                export CONDUIT="${CONDUIT:-mpi}"
            else
                export NETWORK=none
            fi
        fi
        if [[ -z "${USE_CUDA+x}" ]]; then
            if command -v nvcc &> /dev/null; then
                export USE_CUDA=1
            else
                export USE_CUDA=0
            fi
        fi
        if [[ -z "${USE_OPENMP+x}" ]]; then
            TEST_DIR="$(mktemp -d)"
            TEST_SRC="$TEST_DIR/test.cc"
            echo "int main(){}" > "$TEST_SRC"
            TEST_EXE="$TEST_DIR/test.exe"
            if LIBRARY_PATH="${LIBRARY_PATH:-}:$CONDA_PREFIX/lib" "${CXX:-c++}" -o "$TEST_EXE" "$TEST_SRC" -fopenmp &> /dev/null; then
                export USE_OPENMP=1
            else
                export USE_OPENMP=0
            fi
            rm -rf "$TEST_DIR"
        fi
        export GPU_ARCH="${GPU_ARCH:-NATIVE}"
    fi
    # Assuming that nvcc is in PATH, or CUDA_PATH has been set
    # so that FindCUDAToolkit.cmake can function
    export USE_CUDA="${USE_CUDA:-1}"
    export USE_OPENMP="${USE_OPENMP:-1}"
    export NETWORK="${NETWORK:-gasnet1}"
}

function set_mofed_vars {
    if [[ -n "${MOFED_VER+x}" ]]; then
        true
    else
        echo "Error: Unknown MOFED version for platform $PLATFORM" 1>&2
        exit 1
    fi
}

function verbose_export {
    QUOTED_VAL="$(printf "%q" "$2")"
    eval export "$1"="$QUOTED_VAL"
    echo "+ export $1=$QUOTED_VAL"
}

function submit {
    echo -n "Submitted:"
    for TOK in "$@"; do printf " %q" "$TOK"; done
    echo
    "$@"
}

function _run_command {
    echo -n "Command:"
    for TOK in "$@"; do printf " %q" "$TOK"; done
    echo
    "$@"
}

function run_build {
    # Invoke launcher if building on a bare-metal cluster outside of docker, and
    # only if not already inside an allocation
    if [[ -f /proc/self/cgroup ]] && grep -q docker /proc/self/cgroup; then
        true
    elif [[ -n "${SLURM_JOBID+x}" || -n "${LSB_JOBID+x}" ]]; then
        true
    elif [[ "$PLATFORM" == summit ]]; then
        set -- bsub -nnodes 1 -W 60 -P "$ACCOUNT" -I "$@"
    elif [[ "$PLATFORM" == pizdaint ]]; then
        set -- srun -N 1 -p debug -C gpu -t 30 -A "$ACCOUNT" "$@"
    elif [[ "$PLATFORM" == sapling2 ]]; then
        set -- srun --exclusive -N 1 -p gpu -t 60 "$@"
    elif [[ "$PLATFORM" == lassen ]]; then
        set -- lalloc 1 -q pdebug -W 60 -G "$GROUP" "$@"
    else
        true
    fi
    _run_command "$@"
}

function run_command {
    if [[ "$NODRIVER" != 1 ]]; then
        # Find "legate", so we can inject args right after it
        BEFORE=()
        AFTER=("$@")
        while true; do
            TOKEN="${AFTER[0]}"
            AFTER=("${AFTER[@]:1}")
            BEFORE+=("$TOKEN")
            if [[ "$TOKEN" == legate ]]; then break; fi
        done
    fi
    for I in `seq 0 "$((ITERATIONS - 1))"`; do
        if (( ITERATIONS == 1 )); then
            OUT_DIR="$CMD_OUT_DIR"
        else
            mkdir "$HOST_OUT_DIR/$I"
            OUT_DIR="$CMD_OUT_DIR/$I"
        fi
        if [[ "$NODRIVER" != 1 ]]; then
            _run_command "${BEFORE[@]}" --logdir "$OUT_DIR" "${AFTER[@]}"
        else
            _run_command "$@"
        fi
    done
}
