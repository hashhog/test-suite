#!/usr/bin/env python3
"""Write a beamchain wallet backup file for a fixed BIP-39 mnemonic.

beamchain's restorewallet follows Core: restorewallet <name> <backup_file>
(R5 T3, 8a40a06). It no longer takes a mnemonic. The arms still need a wallet
that is a pure function of a fixed seed, so they build the backup file here
and hand it to restorewallet: the BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 rounds,
salt "mnemonic", same as beamchain_bip39:mnemonic_to_seed/2 with an empty
passphrase) is stored in the wallet.json shape beamchain_wallet:save_wallet/1
writes and apply_loaded_wallet/4 reads.

usage: beamchain_seed_backup.py "<mnemonic words>" <out-file>
"""
import hashlib
import json
import sys


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    words = " ".join(argv[1].split())
    out = argv[2]
    seed = hashlib.pbkdf2_hmac("sha512", words.encode("utf-8"),
                               b"mnemonic", 2048, 64)
    wallet = {
        "addresses": [],
        "next_receive": {"p2wpkh": 0, "p2tr": 0, "p2pkh": 0},
        "next_change": {"p2wpkh": 0, "p2tr": 0, "p2pkh": 0},
        "last_synced_height": -1,
        "private_keys_enabled": True,
        "seed": seed.hex(),
    }
    with open(out, "w") as fh:
        json.dump(wallet, fh)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
