from pathlib import Path

path = Path("Attic/Services/TaskStore.swift")
source = path.read_text()
old = '''        case (.exportData, .some):
            if let coveredGeneration = exportStartGenerationByID.removeValue(forKey: update.id) {
                exportedSaveGeneration = max(exportedSaveGeneration, coveredGeneration)
            }
'''
new = '''        case (.exportData, .some):
            if let coveredGeneration = exportStartGenerationByID.removeValue(forKey: update.id),
               update.succeeded {
                exportedSaveGeneration = max(exportedSaveGeneration, coveredGeneration)
            }
'''
if old not in source:
    raise SystemExit("Cloud export completion block not found")
path.write_text(source.replace(old, new, 1))
print("fix(macOS): keep failed CloudKit exports protected")
