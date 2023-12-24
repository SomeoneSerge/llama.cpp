{
  lib,
  config,
  stdenv,
  mkShell,
  cmake,
  ninja,
  pkg-config,
  git,
  python3,
  mpi,
  openblas, # This could be `blas` to enable easy swapping out with `lapack`
  cudaPackages,
  darwin,
  rocmPackages,
  clblast,
  useBlas ? builtins.all (x: !x) [
    useCuda
    useMetalKit
    useOpenCL
    useRocm
  ],
  useCuda ? config.cudaSupport,
  useMetalKit ? stdenv.isAarch64 && stdenv.isDarwin && !useOpenCL,
  useOpenCL ? false,
  useRocm ? config.rocmSupport,
}@inputs:

let
  inherit (lib)
    cmakeBool
    cmakeFeature
    optionals
    versionOlder
    ;

  # It's necessary to consistently use backendStdenv when building with CUDA support,
  # otherwise we get libstdc++ errors downstream.
  stdenv = throw "Use effectiveStdenv instead";
  effectiveStdenv = if useCuda then cudaPackages.backendStdenv else inputs.stdenv;

  # Give a little description difference between the flavors.
  descriptionSuffix =
    if useOpenCL then
      " (OpenCL accelerated)"
    else if useCuda then
      " (CUDA accelerated)"
    else if useRocm then
      " (ROCm accelerated)"
    else if useMetalKit then
      " (MetalKit accelerated)"
    else
      "";

  # TODO: package the Python in this repository in a Nix-like way.
  # It'd be nice to migrate to buildPythonPackage, as well as ensure this repo
  # is PEP 517-compatible, and ensure the correct .dist-info is generated.
  # https://peps.python.org/pep-0517/
  llama-python = python3.withPackages (
    ps: [
      ps.numpy
      ps.sentencepiece
    ]
  );

  # TODO(Green-Sky): find a better way to opt-into the heavy ml python runtime
  llama-python-extra = python3.withPackages (
    ps: [
      ps.numpy
      ps.sentencepiece
      ps.torchWithoutCuda
      ps.transformers
    ]
  );

  # apple_sdk is supposed to choose sane defaults, no need to handle isAarch64
  # separately
  darwinBuildInputs =
    with darwin.apple_sdk.frameworks;
    [ Accelerate ]
    ++ optionals useMetalKit [ MetalKit ]
    ++ optionals (!useMetalKit) [
      CoreVideo
      CoreGraphics
    ];

  cudaBuildInputs = with cudaPackages; [
    cuda_cccl.dev # <nv/target>
    cuda_cudart
    libcublas
  ];

  rocmBuildInputs = with rocmPackages; [
    clr
    hipblas
    rocblas
  ];
in

effectiveStdenv.mkDerivation {
  name = "llama.cpp";
  src = ../../.;
  meta = {
    description = "Inference of LLaMA model in pure C/C++${descriptionSuffix}";
    mainProgram = "llama";
  };

  postPatch = ''
    substituteInPlace ./ggml-metal.m \
      --replace '[bundle pathForResource:@"ggml-metal" ofType:@"metal"];' "@\"$out/bin/ggml-metal.metal\";"

    # TODO: Package up each Python script or service appropriately.
    # If we were to migrate to buildPythonPackage and prepare the `pyproject.toml`,
    # we could make those *.py into setuptools' entrypoints
    substituteInPlace ./*.py --replace "/usr/bin/env python" "${llama-python}/bin/python"
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git
  ] ++ optionals useCuda [ cudaPackages.cuda_nvcc ];

  buildInputs =
    [ mpi ]
    ++ optionals useOpenCL [ clblast ]
    ++ optionals useCuda cudaBuildInputs
    ++ optionals useRocm rocmBuildInputs
    ++ optionals effectiveStdenv.isDarwin darwinBuildInputs;

  cmakeFlags =
    [
      (cmakeBool "LLAMA_NATIVE" true)
      (cmakeBool "LLAMA_BUILD_SERVER" true)
      (cmakeBool "BUILD_SHARED_LIBS" true)
      (cmakeBool "CMAKE_SKIP_BUILD_RPATH" true)
      (cmakeBool "LLAMA_METAL" useMetalKit)
      (cmakeBool "LLAMA_BLAS" useBlas)
    ]
    ++ optionals useOpenCL [ (cmakeBool "LLAMA_CLBLAST" true) ]
    ++ optionals useCuda [ (cmakeBool "LLAMA_CUBLAS" true) ]
    ++ optionals useRocm [
      (cmakeBool "LLAMA_HIPBLAS" true)
      (cmakeFeature "CMAKE_C_COMPILER" "hipcc")
      (cmakeFeature "CMAKE_CXX_COMPILER" "hipcc")

      # Build all targets supported by rocBLAS. When updating search for TARGET_LIST_ROCM
      # in https://github.com/ROCmSoftwarePlatform/rocBLAS/blob/develop/CMakeLists.txt
      # and select the line that matches the current nixpkgs version of rocBLAS.
      # Should likely use `rocmPackages.clr.gpuTargets`.
      "-DAMDGPU_TARGETS=gfx803;gfx900;gfx906:xnack-;gfx908:xnack-;gfx90a:xnack+;gfx90a:xnack-;gfx940;gfx941;gfx942;gfx1010;gfx1012;gfx1030;gfx1100;gfx1101;gfx1102"
    ]
    ++ optionals useMetalKit [ (lib.cmakeFeature "CMAKE_C_FLAGS" "-D__ARM_FEATURE_DOTPROD=1") ]
    ++ optionals useBlas [ (lib.cmakeFeature "LLAMA_BLAS_VENDOR" "OpenBLAS") ];

  # TODO(SomeoneSerge): It's better to add proper install targets at the CMake level,
  # if they haven't been added yet.
  #
  # For example:
  #
  #  1. Avoid GLOBs
  #  2. Add whatever COMPONENTs are missing
  #  3. Fix whatever issues remain with override-ability.
  #
  postInstall = ''
    mv $out/bin/main $out/bin/llama
    mv $out/bin/server $out/bin/llama-server
    mkdir -p $out/include
    cp $src/llama.h $out/include/
  '';

  # Define the shells here, but don't add in the inputsFrom to avoid recursion.
  passthru = {
    shell = mkShell {
      name = "default${descriptionSuffix}";
      description = "contains numpy and sentencepiece";
      buildInputs = [ llama-python ];
    };

    shell-extra = mkShell {
      name = "extra${descriptionSuffix}";
      description = "contains numpy, sentencepiece, torchWithoutCuda, and transformers";
      buildInputs = [ llama-python-extra ];
    };
  };
}
