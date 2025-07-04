# Setting up Spark Helm Chart Repository On GitHub Pages

This guide shows how to host a Helm chart repository using GitHub Pages, providing an easy-to-access location for Helm charts.

## Prerequisites
- GitHub account.
- Helm installed.
- Familiarity with Git and GitHub Pages.

## Setup Instructions

### Step 1: Create a GitHub Repository
1. Log into GitHub, create a new repository, e.g., `my-helm-charts`.
2. Clone the repository to your local machine:
    ```
    git clone https://github.com/your-username/my-helm-charts.git
3. Inside the repo directory, create a charts/ folder for Helm charts:
    ```
    cd my-helm-charts && mkdir chartss
### Step 2: Add and Package Helm Charts
1. Move into the charts/ directory:
    ```
    cd charts
2. Step 2: Add and Package Helm Charts
    ``` 
    helm create your-chart-name
3. Validate the chart’s structure:
    ``` 
    helm lint your-chart-name
4. Package the chart: (This produces a .tgz file in charts/.)

    ``` 
    helm package your-chart-name
### Step 3: Generate the index.yaml File
1. To create an index.yaml for Helm to locate your charts:
    ``` 
    helm repo index . --url https://your-username.github.io/my-helm-charts
2. Update index.yaml with this command each time you add or update charts.
### Step 4: Enable GitHub Pages
1. Commit and push changes to GitHub:
    ```
    git add .
