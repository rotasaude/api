# Final whole-branch review — module 28 (oral health), api

- Branch `feat/mod-28-oral-health`, worktree `apps/api/.claude/mod28`, range `7e086d78..d8d549ba` (28 commits, 163 files, +13.5k/−187).
- Method: `requesting-code-review/code-reviewer.md`. Read-only; no subagents; no specs run (no doubt that needed a run).
- Passes, by area:
  1. models, migration, triggers, encryption, log filters, events;
  2. consultation commands (Start/SaveDraft/Finalize/AddAddendum/Discard/Reassign), Authorization/Cbos/ItemsInput, ClinicalRecord Access/Open;
  3. `DentalCare::*` services (DraftInput, Requirements, Materialize, Plans, Chart, Location, ProcedureLimits, SigtapSituations, Referrals, Json, Vocabulary, Gate, Trail);
  4. LEDI (ConsultationFicha, Fichas::DentalCare/Common/IndividualCare, FichaTypes);
  5. `/dental/*` controllers and commands (charts, plans, endodontics, prosthesis, admin, panels, teams, procedures);
  6. CNES apply, care lines (TeamPopulation, Sources, Evaluate, Rules, Access, controllers), c3_k;
  7. erasure, documents, regulation draft, timeline, health units, seeds and SIGTAP sample;
  8. specs for Review Focus 1–5.
- Not read line by line:
  - the vendored `dicionario-fao.html` (skipped as instructed);
  - the bodies of the data YAMLs (`situations.yml`, `sigtap_situations.yml`, `dental_procedure_limits.yml`);
  - most of `lib/oral_health_crew.rb` (grepped for `Current.city`, `ENV` and production guards only);
  - specs other than the Focus tests and the switch-off tests.
- Inputs: spec, api constraints with Review Focus, contract §16 O1–O27, ledger (O28–O36 and every Ruling, Controller and deferred minor).

## Strengths

- **Privacy discipline is consistent.**
  - Every new model overrides `inspect/to_s/pretty_print/as_json` to ids only (`app/models/dental_*.rb`, `periodontal_*.rb`, `endodontic_*.rb`).
  - Refusals carry the path and never the value (`DentalCare::DraftInput#refuse!`, `Location.parse`).
  - All 10 new `DomainEvents.publish` calls are one-line, with ids and stage codes only: `finalize.rb:64`, `associate_team.rb:22`, `change_prosthesis_stage.rb:28`, `create_prosthesis_order.rb:35`, `save_auxiliary_procedures.rb:26`, `save_ceo_profile.rb:26`, `materialize.rb:56`, `plans.rb:114/116`. Each one is bound in `config/initializers/domain_events.rb`.
  - No new `Platform.audit`, no `Current.city =` and no `Rails.logger` in `app/` or `lib/`.
  - The 3 new `encrypts` are all in `CityEncryption::CITY_KEYED_TARGETS` (`city_encryption.rb:160`), and the reencryption escapes are in the plan and item guards plus `rota_reencryption_only('reason')` on stages.
- **Immutability is enforced in the database, not only in Ruby** (`db/city_triggers.sql`):
  - `kind` and `baseline` are identity columns, read through jsonb so the file still runs on older migrations;
  - the item guard is reused through `to_jsonb(NEW)->>'addendum_id'`;
  - plan, item, endodontic and prosthesis state machines, append-only items, and TRUNCATE refused on the 13 tables.
  - A second line of defence for the FAO limits (`too_many_procedure_codes`, `quantity_exceeds_location_limit`) keeps the form from ever truncating.
- **The finalize design is clean.**
  - `DentalCare::Requirements` returns every refusal with body paths (O2).
  - `Materialize` writes procedures, then events (findings before procedure effects, folded by `seq`), then the plan, periodontal records and endodontics, all before `finalized`.
  - The general consultation path is untouched apart from additive JSON (`kind`, `baseline`, `dental`).
- **Review Focus 1–5 hold end to end**, each with a targeted test (see below).
- **Lock order is documented and consistent** (see Mandatory checks). Switches are read before the transactions.

## Mandatory checks (Task 18 step 1), with evidence

### Review Focus 1–5

| Focus | Code | Test | Holds |
|---|---|---|---|
| 1. The eSB never pulls population or teams from the eSF | `TeamPopulation::TEAMED_CONSULTATIONS` filters `ht.kind IN (70,76)` and `c.kind = 'general'`; `involving` filters `tc.kind = 'general'`; `territory_teams` only uses 70/76; `CareLines::Access.visible_teams` uses 70/76; `CareLines::BaseController#scoped_team` and `PreviewsController` return 404 for an eSB | `spec/commands/cnes/oral_health_teams_spec.rb:65-115` (dental after general, dental-only, territory, `visible_teams`, 404) | yes |
| 2. CEO form without INE; UBS form with the eSB INE | `ConsultationFicha#build`: `professional_without_team` is skipped only for `dental && unit.kind == "ceo"`; `dental_team_ine` prefers the 71 team, then `team_ine` | `spec/services/ledi/dental_ficha_spec.rb:30-52, 69-82` | yes. `localAtendimento = 1` at the CEO is still owed by the PEC proof (O19) |
| 3. Two plans for the same patient | `Plans.open_plan` scopes to the consultation's unit; `Requirements#plan` refuses `plan_item_not_open` at `dental.procedures[i].plan_item_id`; outcome 15 closes only `open_plan(consultation)`; `suggest_completed?` is unit-scoped | `dental_finalize_spec.rb:194-220` | yes |
| 4. Addendum after the plan is completed | `AddAddendum` sets `ficha_changed = stored.except("dental").any?`; `Plans.first_unopen_cancel` runs before any write | `dental_addendum_spec.rb:110-130`: no `ConsultationFichaJob`; counts of addenda, events and DomainEvents unchanged on refusal; item stays `done` | yes |
| 5. CEO registered mid-year | `CeoGoals.first_evaluated` (O35); `risk` only when `month >= since`; `history` only for evaluated months; basic procedures only count with `special_needs` | `ceo_goals_spec.rb:66, 132` | yes |

### `DomainEvents.publish(` in commands, `dental_care` services and controllers

- I ran `git grep -n "DomainEvents.publish(" -- app/commands app/services/dental_care app/controllers/dental_care` and read every new call in full. All are single-line.
- The new events and their payloads:
  - `dental_consultation.finalized`: `consultation_id`, `attendance_id`;
  - `dental.team_association_changed`: `team_id`, `user_id`;
  - `prosthesis_order.stage_changed` (twice): `order_id`, `stage`, `user_id`;
  - `prosthesis_order.created`: `order_id`, `user_id`;
  - `dental.auxiliary_procedures_changed`: `user_id`, `count`;
  - `ceo_profile.changed`: `health_unit_id`, `user_id`;
  - `dental_plan.completed` and `dental_plan.cancelled`: `plan_id`, `consultation_id`.
- `clinical_record.viewed` goes through `DentalCare::Trail` with `access_scope: "dental"` only.
- Pre-existing multi-line calls are untouched.

### The rest of the privacy checks

- No new `Platform.audit(` and no `Current.city =` in the `app/`, `lib/`, `config/` and `db/` diff. No new logger calls.
- Tooth, situation, reason, pregnancy and laboratory never appear in event payloads or in exception messages:
  - `DraftInput::Refused#message` is the reason code;
  - `SigtapSituations` raises a constant message;
  - LEDI failure reasons are codes.
- **One log gap remains:** request parameters (Important 1 below).
- Every new model's `inspect`/`to_s`/`pretty_print`/`as_json` is ids only.
  - `CeoProfile` and `DentalAuxiliaryProcedure` keep the defaults, but hold no patient data.
  - `Consultation` has no override for its new columns. That is pre-existing: it has never overridden anything and relies on the global `inspection_filter`. See Minor 2.

### Lock order

- **Finalize:** attendance → consultation → patient → the patient's open plans (by id) → the prosthesis orders cited (by id). Inside `Materialize`: `EndodonticTreatment` per tooth.
- **AddAddendum:** consultation → patient → plans. This is a prefix of the Finalize order, without the attendance.
- **CreateProsthesisOrder:** consultation (FOR UPDATE), then insert.
- **ChangeProsthesisStage:** order → `professional_links` FOR SHARE. This is the same relative order as Finalize, where the order comes before any link check in Promote and Close. FOR SHARE locks do not conflict with each other.
- **AssociateTeam:** the eSF FOR SHARE → the eSB FOR UPDATE.
  - `Cnes::Apply` sorts the 70/76 teams before the 71s, so ending an eSF never runs while holding the eSB.
  - The deadlock noted by the ledger needs an eSB end in an earlier savepoint of the same batch as the eSF end, which the sort prevents.
  - Theoretical only.
- **No cycles found.**
- **Switches** are all read outside the city transaction:
  - `Start`, `AddAddendum`, `Finalize` (`regulating`), `ClinicalRecord::Open` and `Access.waiting_kind` (computed before the `in_context?` transaction);
  - `ConsultationsController#kinds_and_role`, and `DentalCareGate` as a `before_action`.
  - `ConsultationFicha` deliberately does not read `dental_care`: retained records are still exported.

### Cross-task coherence

- **`plan_item_not_open` paths:**
  - finalize: `dental.procedures[i].plan_item_id`, `dental.plan_changes.cancel[i].item_id`, `dental.plan_changes.cancel_plan`;
  - addendum: `changes.dental.plan_changes.cancel[i].item_id`.
- **`auxiliary_cannot_plan`:** `dental.plan_changes` in finalize, `changes.dental.plan_changes` in the addendum.
- **Draft-time validation errors in the addendum** get the `changes.` prefix (`DraftInput.addendum` rewrites the path). Draft and addendum return the first refusal; finalize returns them all (O2).
- **O25 holds everywhere:** FAO codes and tooth are strings in `DentalCare::Json` (draft, stored, odontogram, events, plans, endodontics, periogram), the top-level `care_type` mirrors `dental.care_type`, and input accepts integers or digit strings.
- **General consultation paths are unchanged:**
  - `Cbos.allowed?(cbo)` keeps its old meaning;
  - `Authorization` and `ItemsInput` default to `kind: "general"`;
  - `SaveDraft` only diverts when `consultation.dental?`;
  - `Finalize` only branches on `dental?`;
  - the options and consultation JSON gain additive keys only (deferred minor of Task 4).

## Issues

### Critical (Must Fix)

None.

### Important (Should Fix)

**1. The prosthesis SIGTAP and the patient id go to the production request log.**

- **Where:** `config/initializers/filter_parameter_logging.rb:100`, `app/controllers/dental_care/prosthesis_orders_controller.rb:12`.
- **What:** the body of `POST /dental/prosthesis_orders` is `{ consultation_id, patient_id, sigtap, laboratory }`.
  - `laboratory` is filtered; `sigtap` is not, and no symbol filter matches it as a substring.
  - Rails logs `Parameters:` at INFO, and production runs `log_level = info`, so every order writes "patient X — 0701070129 (complete upper denture)" to the log.
  - Checked with `ActiveSupport::ParameterFilter` on the current filter list: `sigtap` passes through. The branch's new regex does not cover it either.
- **Why it matters:** the constraints list "procedimento do paciente" as never-in-log. The project precedent is filtering the specialty `target_code` of a regulation request for the same reason.
- **Fix:** add `sigtap` to the module-28 regex. The `sigtap` in the auxiliary-procedures body is city configuration, so filtering it there is harmless. Add a one-line spec that filters a prosthesis-create body, in the style of the `spec/invariants/*` filter assertions.

### Minor (Nice to Have)

1. **A dental draft can still be saved and finalized with `dental_care` off.**
   - `Consultations::SaveDraft` and `Finalize` have no `DentalCare::Gate` check. The addendum with `changes.dental` returns 403 (O33), and `/dental/*` returns 403.
   - The spec is silent. Letting an in-flight draft finish is defensible, since a stuck draft otherwise needs the admin discard, but the asymmetry with O33 should be a deliberate ruling.
   - Today finalizing writes events, plans and the FAO while the dentist cannot load the odontogram or the procedure search.
   - Untested either way.
2. **Columns that are not filtered in SQL bind logs (debug level only, so dev or `RAILS_LOG_LEVEL=debug`).** The pharmacy comment at `filter_parameter_logging.rb:85-94` sets the convention of filtering column names because `inspection_filter` is global. Not filtered:
   - `procedure_code`, `laboratory_name` (the regex is anchored to `laboratory`);
   - `dental_outcomes`, `oral_health_surveillance`, `supplies`, `dental_consultation_type`;
   - `probing_depth_mm`, `recession_mm`, `mobility`, `furcation`, `bleeding`, `canals`, `part`, `site`, `star`.
3. **The prosthesis list puts `patient_id` (and `stage`) in the query string** (`prosthesis_orders_controller.rb:31`). The constraints say "`patient_id` só como segmento de rota". O10 and O23 ask for a `patient_id` filter without saying how it is carried. It is an id, not PII, but it reveals in the access log that patient X has prosthesis orders. A path-segment alias (`/dental/patients/:id/prosthesis_orders`) would fit the other nominal reads. Contract-level call.
4. **A completed plan can keep items `planned` forever.** `Plans.apply!` closes with outcome 15 even when items are still `planned`, and they stay `planned` in a `completed` plan; the later addendum cancel is refused (Focus 4). The spec only says the system *suggests* 15 when everything is done. Consider cancelling the leftovers, as O31 does for `cancel_plan`, or show them as "not done" in the reads.
5. **The finalized `plan_changes.cancel` also lists items the dentist did not cancel.** In `DentalCare::Json#stored`, the items that `cancel_plan` cancels automatically (O31) appear in `cancel`, so the stored form differs from the draft form.

## Deferred minors from the ledger — triage

| Task | Deferred minor | Triage |
|---|---|---|
| 1 | DentalCareGate without a request spec | OK-TO-DEFER: now covered (`charts_spec.rb:76`, admin, panels, procedures, prosthesis specs) |
| 1 | Dead `clinical_record` branch | OK-TO-DEFER |
| 2 | Mixed ARRAY styles in the dump | OK-TO-DEFER |
| 2 | Non-concurrent `idx_consultations_kind_status_finalized` | OK-TO-DEFER (runbook; the ledger says the docs runbook exists, unpublished) |
| 3 | No analyst 403 test on admin routes | OK-TO-DEFER |
| 3 | `PUT procedures []` untested | OK-TO-DEFER |
| 3 | First-PUT race → `RecordNotUnique` 500 | OK-TO-DEFER |
| 3 | CEO list without a cursor | OK-TO-DEFER |
| 4 | `kind`/`baseline` added to every consultation JSON | OK-TO-DEFER (record when the contract closes) |
| 4 | `INTERIM_SITUATIONS` | OK-TO-DEFER: already removed (no references left) |
| 5 | Migration edited in place | OK-TO-DEFER, on one condition: before the browser proof, confirm that no dev or staging DB has applied `20261030900001` (`schema_migrations`) |
| 6 | Redundant `plan_requires_first_consultation` for auxiliaries | OK-TO-DEFER |
| 6 | `exists?` per procedure on every save | OK-TO-DEFER |
| 7 | Tie-break test does not force equal `recorded_at` | OK-TO-DEFER |
| 7 | No "no trail" check on the 422 | OK-TO-DEFER |
| 7 | Plans and endodontics cut at `limit` without a cursor | OK-TO-DEFER |
| 7 | Blank line in `json.rb` | OK-TO-DEFER |
| 8 | Gate checked after validation | OK-TO-DEFER |
| 8 | No request spec for the addendum with `dental` (the controller merges details generically) | OK-TO-DEFER |
| 8 | No signature assertion on the dental addendum | OK-TO-DEFER |
| 8 | Other-unit plan item in the addendum (code is unit-scoped through `open_plan`) | OK-TO-DEFER |
| 9 | A `conducts` addendum on a dental consultation regenerates the FAO | OK-TO-DEFER (see note 1) |
| 10 | Timeline SIGTAP names from the current release | OK-TO-DEFER |
| 10 | No specs for the dentist's controlled prescription, the ASB controlled path, or baseline + notification (the Issuers matrix already allows the dentist) | OK-TO-DEFER (see note 2) |
| 11 | `not_author` vs 404 reveals a consultation exists | OK-TO-DEFER |
| 11 | `Pharmacy::Cursor` reused | OK-TO-DEFER |
| 11 | `laboratory` log filter | OK-TO-DEFER: resolved (in the regex); the gap is `sigtap`, Important 1 |
| 11 | Admin + dentist labelled `administrative` | OK-TO-DEFER |
| 11 | Admin read of a stage not in `clinical_record_administrative_reads` | OK-TO-DEFER (see note 3) |
| 11 | Spec still uses `viewed.delete_all` | OK-TO-DEFER |
| 11 | SIGTAP validated before `not_author` | OK-TO-DEFER |
| 12 | `SaveCeoProfile` without a unit lock | OK-TO-DEFER |
| 13 | `ScreeningFicha.team_ine` without a kind filter | OK-TO-DEFER (see note 4) |
| 13 | Theoretical `AssociateTeam` × `Cnes::Apply` deadlock | OK-TO-DEFER (see Lock order) |
| 13 | `registry_status` accepts an eSB `team_id` | OK-TO-DEFER |
| 13 | `PUT null` does not disassociate | OK-TO-DEFER |
| 13 | Admin GET without a cursor | OK-TO-DEFER |
| 13 | TSB and eSF in an earlier batch untested | OK-TO-DEFER |
| 14 | Empty `to all` assertion | OK-TO-DEFER |
| 15 | Periodontics not isolated in the test | OK-TO-DEFER: resolved in `3d798fb7` |
| 15 | Shallow freeze of the YAML | OK-TO-DEFER: resolved (`deep_freeze`) |
| 16 | Variable shadows the method | OK-TO-DEFER |
| 17 | Interrupted dev scenario left incomplete | OK-TO-DEFER |
| 17 | Coupled counts in `sigtap_reader_spec` | OK-TO-DEFER |
| 17 | Rubocop pending (CI has no rubocop job; still worth running locally before the PR) | OK-TO-DEFER |

**Total: 45 deferred minors. MUST-FIX-BEFORE-MERGE: 0.**

Notes on four of them:

1. **Task 9 (`conducts` addendum).** The regenerated FAO is identical, but if the FAO was already accepted, `refresh!` → `correction!` creates a spurious `correction_pending` that operators will see. It is only reachable if a client sends `conducts` in a dental addendum. Recommended one-liner: exclude `conducts` from `ficha_changed` when `consultation.dental?`.
2. **Task 10 (document specs).** Worth a test before Verified of F-28.7.
3. **Task 11 (administrative read).** The `clinical_record.viewed` trail exists, so it is audited. Only the administrative-reads report misses it. Open a card.
4. **Task 13 (`team_ine`).** Latent: no eSB member writes a FAI or a screening form today. One line (`kind: PRIMARY_CARE_KINDS`) closes it.

## Recommendations

- Fix Important 1 and add the filter spec. Consider Minor 2 in the same commit.
- Get a coordinator ruling on Minor 1 (finalizing a dental draft with the switch off) and pin it with a test.
- Task 18 is still open and gates the merge:
  - the full suite through the "Testes" session (the branch is transversal: `Current`-adjacent access, care lines, CNES, triggers, the 13 new tables);
  - the PEC proof of the three O19 points (CID-10 from the dentist; `gestante` omitted for male patients; `localAtendimento = 1` at the CEO);
  - the runbook gates (`71`, restoration successors, BPA MAC, NT 32 Quadro 3).
- Before migrating dev, check that `20261030900001` was never applied anywhere (Task 5 deferred minor).

## Declined to judge

- **Whether `3224` (every technical oral-health CBO) is the right `cbo_filter` for c3_k:** a coordinator decision in the spec; not reviewed against the methodological note.
- **The B1 numerator restricted to the associated eSF population:** a ledger ruling; whether SIAPS counts the same way waits on the note or the PEC proof.
- **CEO goal values and SIGTAP groups in `ceo_goals.yml`, and the B1 CBO list:** source data and go-live gates, not code.
- **The vocabulary labels and the FAO limits list against the vendored dictionaries:** data transcription, not reviewed line by line.
- **The `laboratories` endpoint listing every active 26a `care_provider`, not only laboratories:** that is the O10 and O23 shape.
- **The full contents of `lib/oral_health_crew.rb`:** dev seed; only checked for city assignment, environment and production guards.
- **The PEC acceptance of the FAO (CID-10, `gestante`, `localAtendimento`):** deferred to the Task 18 proof by contract (O19).
- **TSB/ASB reading the full record of a waiting patient in context (`kind: :any`):** mandated by Desvio 1.

## Assessment

**Ready to merge: With fixes.**

**Reasoning:** the architecture is sound and the five Review Focus scenarios hold with targeted tests. Privacy, immutability, lock order and switch placement are consistent across tasks. One Important gap remains: the prosthesis SIGTAP reaches the production request log next to the patient id, and the fix is a one-word filter plus a spec. Merging also still waits on the Task 18 full suite and the PEC proof.

## Final fix wave

Changes:
- Important 1: the module-28 regex in `filter_parameter_logging.rb` now also filters `sigtap`, `procedure_code`, `procedures`, `outcomes`, `dental_outcomes`, `oral_health_surveillance`, `laboratory_name`, `supplies` and `dental_consultation_type`. This also covers Minor 2 (the SQL bind columns that are single names). The remaining names (`mobility`, `site`, `part`, `star`...) are too generic to add without side effects, so they are left alone. Spec added in `spec/initializers/filter_parameter_logging_spec.rb`; the earlier filters are untouched.
- Minor 5: `DentalCare::Json#stored` drops from `plan_changes.cancel` the items that `cancel_plan` cancelled (same plan, same reason as the plan). Auto-cancelled items stay visible on the plan. Limit: an explicit cancel that has the same text as the plan reason in the same consultation is also hidden. Test in `dental_finalize_spec.rb`.
- O37: `SaveDraft` and `Finalize` refuse a dental consultation with 403 `feature_disabled` / `dental_care` when `DentalCare::Gate.usable?` is false (read outside the transaction). General consultations and the draft discard are unchanged. Request spec in `dental_consultations_spec.rb`.
- O38: outcome 15 with an item still `planned` after the draft changes gives `plan_items_pending` at `dental.dental_outcomes[i]` (adds count; done and cancels discount). The auxiliary keeps `auxiliary_cannot_plan` only. Specs in `dental_finalize_spec.rb`.
- Not changed: patient_id on the prosthesis list, outcome-15 plan with planned items (now refused by O38), and the dental draft with the switch off (now O37).

Command: `bin/test api -w mod28 spec/initializers spec/requests/dental_care spec/requests/dental_consultations_spec.rb spec/commands/consultations spec/commands/consultation_drafts spec/services/dental_care`
Output: `325 exemplos, 0 falhas, 0 pendentes em 127.3s`
