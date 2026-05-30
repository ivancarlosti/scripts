# Lambda scripts

Scripts for Lambda actions to be called by n8n

# Configuration

* Runtime: Python 3.13+
* Architectune: arm64/x86_64 (arm64 is cheaper)
* Timeout: 1 minute
* Requires related policy for each script

# Instruction

* Create function using `.py` code 
* Configure as specified below
* Attach related `.json` policy  on function's role

# Remote call instruction

* Create an IAM user for remote function execution
* Attach related `remotecall_policy_lambda.json` policy on user

# Notes

* AddTag script uses Alias to tag KMS keys
* AddTag script uses Description to tag Route53 zones
* Backup Alert script uses 1 day as range window to gather fails and expired alerts
* Billing and AddTag scripts uses "Tenant" tag set resources

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support
* For personal support and queries, please submit a new issue to have it addressed.
* For commercial related questions, please [**contact me**][ivancarlos] for consulting costs. 

| 🩷 Project support |
| :---: |
If you found this project helpful, consider [**buying me a coffee**][buymeacoffee]
|Thanks for your support, it is much appreciated!|

[ivancarlos]: https://ivancarlos.me
[buymeacoffee]: https://www.buymeacoffee.com/ivancarlos
