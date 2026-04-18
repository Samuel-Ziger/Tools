import sqlite3
import json

conn = sqlite3.connect('/opt/langflow-1.2.0-venv/lib/python3.12/site-packages/langflow/langflow.db')
cursor = conn.cursor()
cursor.execute("SELECT name, data FROM flow")

for name, data in cursor.fetchall():
    flow_json = json.loads(data)
    nodes = flow_json.get('nodes', [])
    for node in nodes:
        node_data = node.get('data', {}).get('node', {})
        template = node_data.get('template', {})
        for key, value in template.items():
            if isinstance(value, dict) and 'value' in value:
                content = str(value['value'])
                if "Solyd" in content:
                    print(f"\n[!] FLAG ENCONTRADA NO FLUXO: {name}")
                    print(f"Componente: {node_data.get('display_name')}")
                    print(f"Conteúdo: {content}")
