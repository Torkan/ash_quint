# :quint_cli marks the tests that run real Quint (needs Node). It isn't
# :quint, which AshQuint.Case uses for its replay tests (quint: <source>).
ExUnit.start(exclude: [:quint_cli])
