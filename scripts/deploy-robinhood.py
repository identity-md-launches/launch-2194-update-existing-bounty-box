#!/usr/bin/env python3
"""Invoke the Foundry script using the one checked-in network configuration.

Dry run by default. Wallet options and --broadcast are explicit operator arguments.
This helper never reads wallet keys or environment configuration.
"""

from pathlib import Path
import re
import subprocess
import sys


def command(arguments):
    root = Path(__file__).resolve().parent.parent
    config = (root / "script" / "RobinhoodConfig.sol").read_text()
    rpc = re.findall(r'string\s+internal\s+constant\s+RPC_URL\s*=\s*"([^"]+)";', config)
    if len(rpc) != 1:
        raise ValueError("RobinhoodConfig.sol must define exactly one RPC_URL")
    # Network, script entry point, and constructor parameters are controlled by the
    # checked-in files. Operators may supply wallet, gas, simulation or broadcast options.
    reserved = ("--rpc-url", "--fork-url", "--chain", "--chain-id", "--sig", "--target-contract")
    for argument in arguments:
        if argument in ("-f", "-s", "-tc") or any(
            argument == option or argument.startswith(option + "=") for option in reserved
        ):
            raise ValueError("Change the reviewed configuration instead of overriding the network or entry point")
    return root, [
        "forge", "script", "script/DeployBountyBox.s.sol:DeployBountyBox",
        "--rpc-url", rpc[0], *arguments,
    ]


def main():
    try:
        root, arguments = command(sys.argv[1:])
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    return subprocess.run(arguments, cwd=root, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
