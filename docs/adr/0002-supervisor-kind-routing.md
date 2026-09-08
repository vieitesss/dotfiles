# Supervisor classifies by kind and never does the work

The interactive Pi session is a supervisor: it classifies each user task as research, implement, or write and spawns a child to do that work, instead of doing the work itself. Reviewer is an automatic successor after every implementer finish, not a user kind. We took the spawn latency to keep that discipline — otherwise the supervisor slides into researching, implementing, and writing, and implement lands without a reviewer.
