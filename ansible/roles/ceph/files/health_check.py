#!/usr/bin/env python3

import argparse
import subprocess
import json
import unittest

def run_ceph_cmd():
    result = subprocess.run(['ceph', 'health', '--format=json', '-n', 'client.health'], stdout=subprocess.PIPE)
    return result.stdout.decode('utf-8')

def get_message(check):
    return check.get('summary', {}).get('message','')

def parse_checks(output):
    j = json.loads(output)
    overall_health = 0 # 0 ok, 1 warn or 2 critical
    message = ''
    checks = list(j.get('checks', {}).keys())
    checks.sort()
    for check_name in checks:
        check = j['checks'][check_name]
        if check['severity'] == 'HEALTH_CRIT':
            overall_health = 2
            message += check_name + ' ' + get_message(check)
            message += '\n'
        if check_name == 'OSDMAP_FLAGS' and get_message(check) == 'noout flag(s) set':
            continue # skip, we don't consider this as a warning
        if check['severity'] == 'HEALTH_WARN':
            if overall_health < 1:
                overall_health = 1
            message += check_name + ' ' + get_message(check)
            message += '\n'

    if j.get('status', '') == 'HEALTH_ERROR' or j.get('status', '') == 'HEALTH_CRIT':
        overall_health = 2
    if message == '':
        if overall_health == 0:
            message = 'OK'
        elif overall_health == 1:
            message = 'Warning'
        else:
            message = 'Critical'
    return overall_health,message


class TestChecks(unittest.TestCase):
    def test_ok(self):
        data = '{"status":"HEALTH_OK"}'
        code, message = parse_checks(data)
        self.assertEqual(code, 0)
        self.assertEqual(message, 'OK')

    def test_warns(self):
        data = '{"checks":{"POOL_APP_NOT_ENABLED":{"severity":"HEALTH_WARN","summary":{"message":"application not enabled on 1 pool(s)"}},"TOO_FEW_PGS":{"severity":"HEALTH_WARN","summary":{"message":"too few PGs per OSD (4 < min 30)"}}},"status":"HEALTH_WARN"}'
        code, message = parse_checks(data)
        self.assertEqual(code, 1)
        self.assertEqual(message, 'POOL_APP_NOT_ENABLED application not enabled on 1 pool(s)\nTOO_FEW_PGS too few PGs per OSD (4 < min 30)\n')

    def test_osdnoout_ignore(self):
        data = '{"checks":{"OSDMAP_FLAGS":{"severity":"HEALTH_WARN","summary":{"message":"noout flag(s) set"}}},"status":"HEALTH_WARN","summary":[{"severity":"HEALTH_WARN","summary":"\'ceph health\' JSON format has changed in luminous. If you see this your monitoring system is scraping the wrong fields. Disable this with \'mon health preluminous compat warning = false\'"}],"overall_status":"HEALTH_WARN"}'
        code, message = parse_checks(data)
        self.assertEqual(code, 0)
        self.assertEqual(message, 'OK')

    def test_critical_check(self):
        data = '{"checks":{"POOL_APP_NOT_ENABLED":{"severity":"HEALTH_CRIT","summary":{"message":"application not enabled on 1 pool(s)"}}}}'
        code, message = parse_checks(data)
        self.assertEqual(code, 2)
        self.assertEqual(message,
                         'POOL_APP_NOT_ENABLED application not enabled on 1 pool(s)\n')

    def test_critical_status(self):
        data = '{"status":"HEALTH_ERROR"}'
        code, message = parse_checks(data)
        self.assertEqual(code, 2)
        self.assertEqual(message,'Critical')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--test', action='store_true', default=False, help='Runs unit tests of check')
    args = parser.parse_args()
    if args.test:
        print("Running unit tests")
        unittest.main()
    else:
        output = run_ceph_cmd()
        code, message = parse_checks(output)
        print(message)
        exit(code)

if __name__ == "__main__":
    # execute only if run as a script
    main()