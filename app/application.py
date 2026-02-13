#!/usr/bin/env python3
"""
Simple Flask application for Elastic Beanstalk deployment test.
This app will be used to test cross-account IAM role injection.
"""

from flask import Flask, jsonify
import os
import requests

application = Flask(__name__)


@app route('/')
def index():
    """Main page"""
    return """
    <h1>Cross-Account IAM Test Application</h1>
    <p>This application is deployed to test AWS Elastic Beanstalk GitHub Actions security.</p>
    <ul>
        <li><a href="/health">Health Check</a></li>
        <li><a href="/iam-role">Check IAM Role</a></li>
    </ul>
    """


@application.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'message': 'Application is running'
    })


@application.route('/iam-role')
def iam_role():
    """
    Check what IAM role this EC2 instance is using.
    CRITICAL: If this returns a role from Account B (142531840183),
    we have a cross-account IAM injection vulnerability!
    """
    try:
        # Get IAM role name from metadata service
        metadata_url = 'http://169.254.169.254/latest/meta-data/iam/security-credentials/'
        response = requests.get(metadata_url, timeout=2)
        role_name = response.text.strip()

        # Get role credentials
        credentials_url = f'{metadata_url}{role_name}'
        creds_response = requests.get(credentials_url, timeout=2)
        credentials = creds_response.json()

        # Extract account ID from role ARN (if present)
        account_id = None
        if 'RoleArn' in credentials:
            # Format: arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME
            parts = credentials['RoleArn'].split(':')
            if len(parts) >= 5:
                account_id = parts[4]

        return jsonify({
            'role_name': role_name,
            'role_arn': credentials.get('RoleArn', 'Not available'),
            'account_id': account_id,
            'access_key_id': credentials.get('AccessKeyId', 'N/A')[:20] + '...',
            'expiration': credentials.get('Expiration', 'N/A'),
            'warning': 'If account_id is 142531840183, VULNERABILITY CONFIRMED!'
        })

    except Exception as e:
        return jsonify({
            'error': str(e),
            'message': 'Could not retrieve IAM role information'
        }), 500


if __name__ == '__main__':
    # Run on port 8080 for Elastic Beanstalk
    port = int(os.environ.get('PORT', 8080))
    application.run(host='0.0.0.0', port=port, debug=False)
