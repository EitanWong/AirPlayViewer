# Third-party components

| Component | Location and provenance | License notice |
| --- | --- | --- |
| UxPlay protocol library | `Sources/CAirPlay/uxplay`; recorded upstream revision in [VERSIONS.txt](VERSIONS.txt) | [GPL-3.0 text](licenses/UxPlay-GPL-3.0.txt); retain the notices in individual files |
| llhttp | Included in the recorded UxPlay tree | [MIT notice](licenses/llhttp-MIT.txt) |
| playfair | Included in the recorded UxPlay tree | [Upstream license](licenses/playfair-LICENSE.md) |
| libplist and libcnary | `Sources/CPlist`; recorded upstream revision in [VERSIONS.txt](VERSIONS.txt) | [LGPL-2.1 text](licenses/libplist-LGPL-2.1.txt), [libcnary notice](licenses/libcnary-COPYING.txt) |
| OpenSSL 3 | Statically linked from `OPENSSL_PREFIX/lib/libcrypto.a`; CI logs the installed version when available | Apache-2.0; the build includes the license file from the installation |

`scripts/vendor-sources.sh` replaces both vendored directories. Before an update, check the exact upstream revisions and licenses, check that both source trees are clean, and account for any local vendor changes before running it. Review the resulting source and notice diffs and run CI.

The notices in the local app bundle are not a substitute for reviewing the final license, corresponding source, and static-link distribution obligations before publishing.
