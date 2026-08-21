#!/usr/bin/env python3

import argparse
import json
import os
import re
import sys

import pexpect


class RedactedLog:
    def __init__(self, stream, secrets):
        self.stream = stream
        self.secrets = [value for value in secrets if value]
        self.buffer = ""

    def redact(self, data):
        for secret in self.secrets:
            data = data.replace(secret, "[REDACTED_SUBSCRIPTION]")
        return re.sub(
            r"https://[^\s\x1b]+",
            "https://[REDACTED]",
            data,
        )

    def write(self, data):
        self.buffer += data
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            self.stream.write(self.redact(f"{line}\n"))
            self.stream.flush()

    def flush(self):
        self.stream.flush()

    def finish(self):
        if self.buffer:
            self.stream.write(self.redact(self.buffer))
            self.buffer = ""
        self.stream.flush()


def load_scenario(path):
    with open(path, "r", encoding="utf-8") as handle:
        scenario = json.load(handle)
    if not isinstance(scenario.get("command"), list) or not scenario["command"]:
        raise ValueError("scenario.command must be a non-empty string array")
    if not isinstance(scenario.get("steps"), list):
        raise ValueError("scenario.steps must be an array")
    return scenario


def step_value(step, key, environment):
    if key in step:
        return str(step[key])
    env_key = step.get(f"{key}_env")
    if env_key:
        value = environment.get(env_key)
        if value is None:
            raise ValueError(f"required environment variable is missing: {env_key}")
        return value
    raise ValueError(f"step requires {key} or {key}_env")


def run_scenario(scenario):
    environment = os.environ.copy()
    environment.update({str(k): str(v) for k, v in scenario.get("env", {}).items()})
    secret_names = scenario.get("secret_env", [])
    secrets = [environment.get(name, "") for name in secret_names]
    command = scenario["command"]
    child = pexpect.spawn(
        command[0],
        command[1:],
        cwd=scenario.get("cwd"),
        env=environment,
        encoding="utf-8",
        timeout=scenario.get("timeout", 120),
    )
    redacted_log = RedactedLog(sys.stdout, secrets)
    child.logfile_read = redacted_log
    echo_disabled = False

    for index, step in enumerate(scenario["steps"], start=1):
        timeout = step.get("timeout", scenario.get("timeout", 120))
        try:
            if "expect" in step:
                child.expect(str(step["expect"]), timeout=timeout)
            elif "expect_exact" in step:
                child.expect_exact(str(step["expect_exact"]), timeout=timeout)
            elif step.get("expect_eof") is True:
                child.expect(pexpect.EOF, timeout=timeout)
            else:
                raise ValueError("step requires expect, expect_exact, or expect_eof")

            if echo_disabled:
                child.setecho(True)
                echo_disabled = False

            if "send" in step or "send_env" in step:
                sensitive = "send_env" in step
                if sensitive:
                    child.setecho(False)
                    echo_disabled = True
                child.send(step_value(step, "send", environment))
            elif "sendline" in step or "sendline_env" in step:
                sensitive = "sendline_env" in step
                if sensitive:
                    child.setecho(False)
                    echo_disabled = True
                child.sendline(step_value(step, "sendline", environment))
            elif step.get("send_escape") is True:
                child.send("\x1b")
        except Exception as error:
            raise RuntimeError(f"PTY scenario failed at step {index}: {step}") from error

    child.close()
    redacted_log.finish()
    expected_exit = int(scenario.get("expected_exit", 0))
    actual_exit = child.exitstatus
    if actual_exit is None and child.signalstatus is not None:
        actual_exit = 128 + child.signalstatus
    if actual_exit != expected_exit:
        raise RuntimeError(f"expected exit {expected_exit}, got {actual_exit}")


def main():
    parser = argparse.ArgumentParser(description="Run a redacted MiPilot PTY scenario")
    parser.add_argument("scenario", help="JSON scenario path")
    options = parser.parse_args()
    run_scenario(load_scenario(options.scenario))


if __name__ == "__main__":
    main()
