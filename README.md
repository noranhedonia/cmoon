## C. MOON
All source code in this repository is free (licensed under MIT),
and the LaTeX technical documentation is in the public domain (licensed under CC0).
Feel free to do whatever you want with this stuff.

You can contact me at discord @noranhedonia, I'm open for creative collaboration.

### Subprojects
This repository hosts:
- An engine library.
- A video game application.
- The LaTeX technical documentation.
- Few offline tools and scripts in different languages.

#### Engine (WIP)
TODO. Document the engine features.

#### GDD (WIP)
TODO. A first-person shooter.

### Building the project (WIP)
You will need the [Zig programming language](https://ziglang.org/) (version 0.14 or later)
and the [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) (version 1.4.304 or later) installed.
You'll also need the [Slang shader language](https://shader-slang.org/slang/) and SPIR-V tools, 
both are distributed with the Vulkan SDK.

TODO. Document the build process.
```
$ zig build
```

*Right now only the `x86_64 linux/wayland vulkan` build is supported, other platforms are either unstable or have unimplemented backends!*

### My hardware
I am testing this project on the following hardware and platforms:
- *Main PC x86_64 linux* - AMD Ryzen 7 5700X (16), Radeon RX 7600 8GB, 32GB 3200MGz CL16 DDR4, M.2 NVMe 3.0 x4 (3300/3000 MB/s read/write).
- *Huawei Matebook 14 2020, linux and windows* - AMD Ryzen 5 4600H (12), Radeon Vega (integrated), 16GB DDR4.
- *ODROID-M2, Aarch64 linux* - RK3588S2 SoC [Cortex-A76 (4), Cortex-A55 (4), GPU Mali-G610 MC4], 8GB LPDDR5.
- *StarFive VisionFive 2, rv64gc linux* - JH7110 SoC (8), GPU IMG BXE4-32 MC1, 8GB LPDDR4.

I may make some benchmarks later.
