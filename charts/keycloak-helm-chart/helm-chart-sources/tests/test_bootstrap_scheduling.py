"""Render-only scheduling/service contracts; no cluster or real credentials."""
from pathlib import Path
import subprocess
import unittest

import yaml

CHART = Path(__file__).resolve().parents[1]


def matches(selector, labels):
    if any(labels.get(key) != value for key, value in selector.get('matchLabels', {}).items()):
        return False
    for expression in selector.get('matchExpressions', []):
        key, operator = expression['key'], expression['operator']
        values = expression.get('values', [])
        if operator == 'In' and labels.get(key) not in values:
            return False
        if operator == 'NotIn' and labels.get(key) in values:
            return False
        if operator == 'Exists' and key not in labels:
            return False
        if operator == 'DoesNotExist' and key in labels:
            return False
    return True


class BootstrapSchedulingTest(unittest.TestCase):
    def test_hook_can_share_server_nodes_and_is_not_a_service_endpoint(self):
        for release, chart_name in [('keycloak', 'keycloak'), ('identity-prod', 'custom-identity')]:
            with self.subTest(release=release):
                result = subprocess.run([
                    'helm', 'template', release, str(CHART), '--namespace', 'identity',
                    '--set-string', f'nameOverride={chart_name}',
                    '--set-string', 'bootstrapAdminUser.tenantDid=did:example:fixture',
                    '--set-string', 'bootstrapAdminUser.actorDid=did:example:actor',
                    '--set-string', 'bootstrapAdminUser.actorType=human'],
                    check=True, text=True, capture_output=True)
                resources = [item for item in yaml.safe_load_all(result.stdout) if item]
                server = next(item for item in resources if item['kind'] == 'StatefulSet')
                hook = next(item for item in resources if item['kind'] == 'Job')
                server_labels = server['spec']['template']['metadata']['labels']
                hook_labels = hook['spec']['template']['metadata']['labels']
                # Preserve the immutable StatefulSet selector on existing installations.
                self.assertEqual({'matchLabels': {'app.kubernetes.io/name': chart_name,
                                                  'app.kubernetes.io/instance': release}},
                                 server['spec']['selector'])
                self.assertFalse(matches(server['spec']['selector'], hook_labels))
                affinity = server['spec']['template']['spec']['affinity']['podAntiAffinity']
                terms = affinity['requiredDuringSchedulingIgnoredDuringExecution'] + [
                    item['podAffinityTerm']
                    for item in affinity['preferredDuringSchedulingIgnoredDuringExecution']]
                for term in terms:
                    self.assertTrue(matches(term['labelSelector'], server_labels))
                    self.assertFalse(matches(term['labelSelector'], hook_labels))
                    self.assertFalse(matches(term['labelSelector'], {}))
                    another_release = dict(server_labels, **{'app.kubernetes.io/instance': 'unrelated'})
                    self.assertFalse(matches(term['labelSelector'], another_release))
                services = [item for item in resources if item['kind'] == 'Service']
                self.assertTrue(services)
                for service in services:
                    selector = {'matchLabels': service['spec']['selector']}
                    self.assertTrue(matches(selector, server_labels))
                    self.assertFalse(matches(selector, hook_labels))


if __name__ == '__main__':
    unittest.main()
