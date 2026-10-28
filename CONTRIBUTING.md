# Contributing

The code uses only the Python standard library (3.9 or later). Run the tests before proposing a change:

```sh
python3 -m unittest discover -s tests -t .
```

For page changes, run `python3 scripts/demo.py` and check the dashboard at desktop and phone widths
in light and dark mode. Use the demo's fictional data for screenshots; never attach real logs,
prompts or usage data to an issue or pull request.

New log formats or limit endpoints need a test with a small, made-up sample of the format.
