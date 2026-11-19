#!/bin/bash
# Собирает dist/vpn-setup-prompt.md — всю инструкцию одним файлом для моделей
# без доступа к файлам: вставить в системный промпт, custom instructions или
# первое сообщение. Запускать после любой правки SKILL.md, runbook.md,
# troubleshooting.md или scripts/.
set -euo pipefail
cd "$(dirname "$0")/.."

{
    echo '<!-- Сгенерировано tools/build-prompt.sh — не править руками. -->'
    echo
    # SKILL.md без YAML-frontmatter
    awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' SKILL.md
    echo
    echo '---'
    echo
    cat runbook.md
    echo
    echo '---'
    echo
    cat troubleshooting.md
    echo
    echo '---'
    echo
    echo '# Скрипты для сервера'
    echo
    echo 'Человек сохраняет каждый в файл с этим именем и ставит, как сказано в runbook (Этап 1.2).'
    for s in scripts/*; do
        echo
        echo "## \`$(basename "$s")\`"
        echo
        echo '```bash'
        cat "$s"
        echo '```'
    done
} > dist/vpn-setup-prompt.md

echo "dist/vpn-setup-prompt.md: $(wc -l < dist/vpn-setup-prompt.md) строк, $(wc -c < dist/vpn-setup-prompt.md) байт"
