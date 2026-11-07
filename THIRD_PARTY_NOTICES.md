# Third-party notices

## film-dust

- Author: Magnus Holmes.
- Source: https://github.com/magholmes/film-dust
- Revision: `fcf68d6c6a77e4373db28f878c7f80f7b8934f3f`.
- License: MIT, retained at `vendor/film-dust/LICENSE.txt`.
- The runtime algorithms and embedded inference weights are in `vendor/film-dust/engine`. PURE Neg adds category gates to the detector, pipeline and scene pass and uses the original model weights.
- The optional native detector kernels and Node-API build source are in `vendor/film-dust/native`.
- Additional scikit-image, Node-API and model provenance notices are retained verbatim in `vendor/film-dust/NOTICES.txt`. Adobe UXP SDK files and Photoshop UI are not included or required.

The upstream scene model is described as derived from torchvision MobileNetV3-small ImageNet weights. The [full torchvision BSD-3-Clause license](licenses/torchvision-LICENSE) is also included in the application bundle under `Contents/Resources/ThirdPartyLicenses/`. See the upstream notices for the model training provenance.

## Node.js

The macOS application bundles the Node.js runtime. Its complete license, including third-party notices, is supplied in `Contents/Resources/runtime/LICENSE`; the checked-in copy used by this build is under `licenses/`.

## Application artwork

The PURE Neg branding, support payment artwork, and the example photographs used in documentation are separate from the software's MIT license. See the project README for the photo credits.

## Sparkle

Updater-enabled macOS builds include Sparkle. Its license is bundled in the app's third-party licenses. [Sparkle source and license](https://github.com/sparkle-project/Sparkle)
