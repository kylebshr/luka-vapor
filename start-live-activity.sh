#!/bin/bash

curl -X POST http://127.0.0.1:8080/start-live-activity \
  -H "Content-Type: application/json" \
  -d '{
    "pushToken": "80449c6abdc5dc0590a462dc0b845c38fd2d056c2b636d0f1287ec64bf98ebdd8113865795e880a8aee3071d58ae89ba8e068f3016e497eda046b3fa4e65122321e9c5888c2bf511cd9768a7ef1b14f8",
    "accountID": "3D511AEA-9550-4826-B0F9-EAF1F1F51CDD",
    "sessionID": "933A5C2B-81B9-48E3-A860-1CC7AC1C7ED8",
    "accountLocation": "usa",
    "duration": 1,
    "environment": "development"
  }'
