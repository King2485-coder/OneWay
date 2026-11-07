# OneWay open-source licensing

Effective November 7, 2026, OneWay-owned original source code in this repository is licensed under the GNU Affero General Public License, version 3 only (`AGPL-3.0-only`). The complete license is in [LICENSE](LICENSE).

Copyright (C) 2026 OneWay Technologies Inc.

## Scope and third-party materials

This grant covers source code that OneWay owns and has authority to license. Existing file-specific and third-party licenses and copyright notices remain in force; this grant does not relicense dependencies or third-party material. Retain applicable notices and satisfy each dependency's license.

No trademark license is granted for OneWay names or logos. Non-code artwork, photographs, fonts, and other media are not covered by this source-code grant unless explicitly licensed separately. That distinction does not restrict rights in source code granted by the AGPL.

## Distribution

Recipients may use, study, modify, and redistribute covered code under AGPL-3.0-only, including for commercial purposes. Follow the license's corresponding-source, notice, and applicable network-interaction obligations. A public repository alone does not establish compliance for a particular app binary or distribution channel.

The repository is a published source snapshot. It does not represent that every unpublished local development change or source file needed for a future binary has been released. A future release must identify its exact source revision, build instructions, dependencies, and required corresponding source.

## Encryption status

This licensing change does not enable production end-to-end encryption or certify the security of OneWay. Prototype and architecture work must not be represented as completed production E2EE.

The exact libsignal integration, TestFlight/App Store distribution terms, export requirements, and independent security review still require their separate review. Open sourcing does not itself close those gates.

## Secrets and user data

Credentials, signing keys, production configuration secrets, and private user data are not source-code release material. Use placeholders and independently provision development credentials; do not contribute private material.
