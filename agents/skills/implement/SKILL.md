---
name: implement
description: Implement a piece of work based on a set of issues or specs.
disable-model-invocation: true
---

Implement the work described by the user by:
- reading the `specs` indicated by the user, if the repository works with SDD
- using `/tdd` if the repository works with TDD.
- implementing directly the code if it's trivial (well defined; very specific; the user asked you to change something without any kind of doubts)

If the task is not trivial, ask to use either SDD or TDD if the repository is not using any of them at the moment.

Run typechecking regularly, single test files regularly, and the full test suite once at the end if possible.

Once done, review the changes, looking for refactors/issues around the code.

