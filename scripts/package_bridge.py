"""Build the small local VSIX without downloads or a package manager."""
from pathlib import Path
import json
import zipfile

repo = Path(__file__).resolve().parent.parent
package = json.loads((repo / 'cursor-bridge/package.json').read_text())
dest = repo / 'dist/agent-isle-bridge.vsix'
dest.parent.mkdir(exist_ok=True)
manifest = '''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
<Metadata><Identity Language="en-US" Id="agent-isle-bridge" Version="%s" Publisher="agent-isle"/><DisplayName>Agent Isle Local Bridge</DisplayName><Description xml:space="preserve">Local AI chat and terminal navigation.</Description><Tags>local,terminal</Tags><Categories>Other</Categories><GalleryFlags>Public</GalleryFlags><Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.85.0"/></Properties><License>extension/LICENSE</License></Metadata>
<Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/><Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets></PackageManifest>''' % package['version']
types = '''<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="vsixmanifest" ContentType="text/xml"/><Default Extension="md" ContentType="text/markdown"/><Default Extension="txt" ContentType="text/plain"/></Types>'''
with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('extension.vsixmanifest', manifest)
    z.writestr('[Content_Types].xml', types)
    for file in (repo / 'cursor-bridge').glob('*'):
        if file.is_file():
            z.write(file, 'extension/' + file.name)
    z.write(repo / 'LICENSE', 'extension/LICENSE')
print(dest)
