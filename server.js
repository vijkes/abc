const express = require('express');
const bodyParser = require('body-parser');
const axios = require('axios');
const { Octokit } = require('@octokit/rest');
const dotenv = require('dotenv');
const path = require('path');

// Load environment variables
dotenv.config();

const app = express();
const port = process.env.PORT || 3000;

// Middleware
app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// Routes
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Handle form submission
app.post('/deploy', async (req, res) => {
  try {
    const { name, domain, subdomain, credits } = req.body;
    
    if (!name || !domain || !credits) {
      return res.status(400).json({ 
        success: false, 
        message: 'Missing required fields' 
      });
    }

    // Initialize GitHub API client
    const octokit = new Octokit({
      auth: process.env.GITHUB_PAT
    });

    // GitHub repository information
    const owner = process.env.GITHUB_OWNER;
    const repo = process.env.GITHUB_REPO;
    
    // Create a payload to pass to GitHub Actions
    const deploymentData = {
      ref: 'main', // branch to trigger the workflow on
      inputs: {
        name: name,
        domain: domain,
        subdomain: subdomain || '',
        credits: credits
      }
    };

    // Trigger the GitHub workflow
    const response = await octokit.actions.createWorkflowDispatch({
      owner,
      repo,
      workflow_id: 'deploy.yml', // Name of your GitHub Actions workflow file
      ref: 'main',
      inputs: deploymentData.inputs
    });

    console.log('GitHub Actions workflow triggered successfully');
    
    // Log the deployment request
    console.log('Deployment requested:', {
      timestamp: new Date().toISOString(),
      name,
      domain,
      subdomain: subdomain || 'N/A',
      credits
    });

    return res.status(200).json({
      success: true,
      message: 'Deployment process initiated successfully',
      deploymentId: Date.now().toString() // Just a placeholder ID
    });
  } catch (error) {
    console.error('Deployment error:', error);
    return res.status(500).json({
      success: false,
      message: 'Failed to initiate deployment',
      error: error.message
    });
  }
});

// Start the server
app.listen(port, () => {
  console.log(`Deployment form server running on port ${port}`);
});