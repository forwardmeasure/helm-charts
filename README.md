# ForwardMeasure Helm Charts

## To Create a Chart
Create the necessary ```Helm``` artifacts, e.g., ```deployment.yaml```, ```service.yaml```, ```values.yaml```, etc. using the existing charts as blueprints. Ensure that the ```Chart.yaml``` is properly set up.

## To Push the Newly Created Chart
Run the ```publish_charts.sh``` script that will push the code to the helm-charts repo.

## To Publish the Newly Pushed Chart
You will find your newly pushed chart in its own branch. Once you merge that branch into develop, the newly created chart will be visible once you run:

    helm repo update forwardmeasure 
    helm search repo forwardmeasure
