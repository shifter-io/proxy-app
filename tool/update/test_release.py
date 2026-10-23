import argparse
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import release


class PublisherTests(unittest.TestCase):
    def setUp(self):
        root = Path.home() / 'Library/Caches/shifter-vpn/build/application-updates/publisher-tests'
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = self.root/'private.pem'
        subprocess.run([release.openssl(),'genpkey','-algorithm','ED25519','-out',str(self.key)],check=True,capture_output=True)
        self.key.chmod(0o600)
        (self.root/'keys.json').write_text(json.dumps({'test':base64.b64encode(release.public_key(self.key)).decode()}))
        self.template=json.loads(Path(__file__).with_name('feed.example.json').read_text())
        self.template['releases'][0]['artifact']['expectedSigner']='a'*64
        (self.root/'template.json').write_text(json.dumps(self.template))
        (self.root/'package.apk').write_bytes(b'test package bytes')
        self.args=argparse.Namespace(template=str(self.root/'template.json'),key=str(self.key),key_id='test',trusted_keys=str(self.root/'keys.json'),
            output=str(self.root/'cdn'),scratch=str(self.root),sequence=1,artifact=['android-0.2.0-2='+str(self.root/'package.apk')])

    def test_sign_publish_refresh_and_immutable_urls(self):
        release.publish(self.args)
        feed=self.root/'cdn/direct/android/universal/stable.json'
        envelope=json.loads(feed.read_bytes())
        payload=base64.b64decode(envelope['payloadBase64'])
        (self.root/'payload').write_bytes(payload)
        (self.root/'signature').write_bytes(base64.b64decode(envelope['signatureBase64']))
        subprocess.run([release.openssl(),'pkey','-in',str(self.key),'-pubout','-out',str(self.root/'public.pem')],check=True,capture_output=True)
        subprocess.run([release.openssl(),'pkeyutl','-verify','-rawin','-pubin','-inkey',str(self.root/'public.pem'),'-in',str(self.root/'payload'),'-sigfile',str(self.root/'signature')],check=True,capture_output=True)
        self.assertEqual(json.loads(payload)['releases'][0]['artifact']['sha256'],release.sha256(self.root/'package.apk'))
        with self.assertRaises(ValueError): release.publish(self.args)
        self.args.sequence=2;self.args.artifact=[];release.publish(self.args)
        self.args.sequence=3;self.args.artifact=['android-0.2.0-2='+str(self.root/'package.apk')]
        (self.root/'package.apk').write_bytes(b'replaced')
        with self.assertRaises(ValueError):release.publish(self.args)
        self.assertEqual(json.loads(base64.b64decode(json.loads(feed.read_bytes())['payloadBase64']))['feedSequence'],2)
        self.assertFalse((self.root/'cdn/.shifter-publish.lock').exists())

    def test_reject_untrusted_signer_and_unsafe_paths(self):
        (self.root/'keys.json').write_text('{}')
        with self.assertRaises(ValueError):release.publish(self.args)
        for path in ('../bad','/absolute','https://bad/a','a/%2e%2e/b'):
            with self.assertRaises(ValueError):release.safe_path(path)
        with self.assertRaises(ValueError):release.strict_load('{"a":1,"a":2}')


if __name__=='__main__':unittest.main()
