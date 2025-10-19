#!/bin/bash

curl -X POST http://127.0.0.1:8080/start-live-activity \
  -H "Content-Type: application/json" \
  -d '{
    "pushToken": "123",
    "accountID": "3D511AEA-9550-4826-B0F9-EAF1F1F51CDD",
    "sessionID": "933A5C2B-81B9-48E3-A860-1CC7AC1C7ED8",
    "accountLocation": "usa",
    "duration": 1
  }'
