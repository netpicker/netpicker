#!/bin/bash

# Package the Helm chart
helm package netpicker-chart

# Create an index file
helm repo index --url https://example.com/charts .

echo "Helm chart packaged successfully!"
echo "You can install it with: helm install netpicker ./netpicker-chart-0.1.0.tgz" 