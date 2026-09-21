# Fix a failure from diagnostics

Review the repository and the diagnostic material at the path I provide.

1. Identify the failure, affected component, and likely root cause.
2. Cite the specific log entries and code paths supporting the diagnosis.
3. Create a new `ai/` topic branch.
4. Implement the smallest maintainable fix without weakening security controls.
5. Add or update tests that would have caught the failure.
6. Run relevant tests, linters, `bash -n` for shell files, and Compose validation where applicable.
7. Update affected documentation.
8. Review the final diff for secrets, security regressions, failure handling, logging, availability, and Raspberry Pi resource impact.
9. Commit the change, then stop and provide a PR-ready summary. Do not merge or deploy.
