module Regulation
  # Documentos RIRA de exemplo (módulo 26c, Task 9): os fatos de cada situação
  # montados em memória, sem banco, com dados fictícios (CPF/CNS gerados com os
  # dígitos verificadores certos, CNES de teste). A CI (job `rira-validate`)
  # entrega os JSON ao validador oficial do HL7 contra o pacote RIRA 1.0.0.
  #
  #   Regulation::RiraExamples.write(dir, now:) -> [Pathname]
  #
  # Cada caso passa no `RiraSkeleton.problems == []` e na `RndsValidation` (o
  # spec confere); nenhum caso afrouxa a conferência.
  module RiraExamples
    Case = Data.define(:facts, :status, :last_rnds_id)
    SyncStub = Data.define(:bundle_identifier, :last_rnds_id)

    BUNDLE_IDENTIFIER = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b".freeze
    REPLACED_ID = "0b9f4e52-7c1a-4d36-9e8b-5a2c1d3e4f60".freeze
    REQUESTER_CNES = "2345678".freeze
    AUTHOR_CNES = "1234567".freeze
    OWN_UNIT_CNES = "3456789".freeze
    PROVIDER_CNES = "4567890".freeze
    CONSULT_SIGTAP = "0301010072".freeze # consulta médica em atenção especializada (grupo 03)
    CARDIOLOGIST_CBO = "225120".freeze
    GENERALIST_CBO = "225125".freeze

    REQUESTED = Time.utc(2026, 11, 2, 12, 0).freeze
    AUTHORIZED = Time.utc(2026, 11, 4, 12, 0).freeze
    SCHEDULED = Time.utc(2026, 11, 12, 13, 0).freeze
    SCHEDULED_END = (SCHEDULED + 20.minutes).freeze

    def self.cpf(n)
      digits = format("%09d", 413_000_000 + n).chars.map(&:to_i)
      first = CitizenIdentity::Cpf.check_digit(digits)
      (digits + [ first, CitizenIdentity::Cpf.check_digit(digits + [ first ]) ]).join
    end

    def self.facts(cpf_seed, **over)
      RiraFacts.new(**{
        patient_cpf: cpf(cpf_seed), patient_cns: nil, requester_cnes: REQUESTER_CNES, author_cnes: AUTHOR_CNES,
        requester_id: "2926", target_type: "specialty", target_code: CARDIOLOGIST_CBO, sigtap: CONSULT_SIGTAP,
        sigtap_valid: true, performer_cnes: OWN_UNIT_CNES, performer_cbo: CARDIOLOGIST_CBO, priority: "routine",
        cid10: "I10", ciap2: nil, requested_at: REQUESTED, authorized_at: AUTHORIZED, scheduled_at: nil,
        scheduled_ends_at: nil, absences: [].freeze, status_times: {}.freeze, own_network: true
      }.merge(over))
    end

    def self.scheduled(seed, **over) = facts(seed, scheduled_at: SCHEDULED, scheduled_ends_at: SCHEDULED_END, **over)

    def self.target(status, at) = RndsStatus::Target.new(status: status, at: at)

    def self.missed(cnes)
      RiraFacts::Slot.new(starts_at: SCHEDULED, ends_at: SCHEDULED_END, cnes: cnes, missed_at: SCHEDULED + 1.day)
    end

    CASES = {
      pending_routine: Case.new(facts(1), target("pending", REQUESTED), nil),
      pending_urgent: Case.new(facts(2, priority: "urgent"), target("pending", REQUESTED), nil),
      returned: Case.new(
        facts(3, patient_cpf: nil, patient_cns: Professionals::Cns.generate("rira-examples:3")),
        target("returned-to-requester", REQUESTED + 1.day), nil
      ),
      booked_own: Case.new(scheduled(4, performer_cbo: GENERALIST_CBO, target_code: GENERALIST_CBO),
                           target("booked", AUTHORIZED + 1.day), nil),
      booked_external: Case.new(scheduled(5, own_network: false, performer_cnes: PROVIDER_CNES),
                                target("booked", AUTHORIZED + 1.day), nil),
      attended_procedure_group03: Case.new(
        scheduled(6, target_type: "procedure", target_code: CONSULT_SIGTAP, performer_cbo: GENERALIST_CBO),
        target("attended", SCHEDULED + 2.hours), nil
      ),
      cancelled: Case.new(facts(7), target("cancelled", REQUESTED + 3.days), nil),
      absence: Case.new(scheduled(8, absences: [ missed(OWN_UNIT_CNES) ].freeze),
                        target("absence", SCHEDULED + 1.day), nil),
      absence_contracted: Case.new(
        scheduled(9, own_network: false, performer_cnes: PROVIDER_CNES, absences: [ missed(PROVIDER_CNES) ].freeze),
        target("absence", SCHEDULED + 1.day), nil
      ),
      excluded: Case.new(facts(10), target("excluded", REQUESTED + 5.days), nil),
      pending_ciap2: Case.new(facts(11, cid10: nil, ciap2: "K86"), target("pending", REQUESTED), nil),
      booked_replacing: Case.new(scheduled(12, performer_cbo: GENERALIST_CBO, target_code: GENERALIST_CBO),
                                 target("booked", AUTHORIZED + 2.days), REPLACED_ID)
    }.freeze

    module_function

    # O documento de um caso (Hash de chaves String).
    def bundle(definition, now:)
      sync = SyncStub.new(bundle_identifier: BUNDLE_IDENTIFIER, last_rnds_id: definition.last_rnds_id)
      RiraBundle.build(facts: definition.facts, sync: sync, status: definition.status, now: now)
    end

    # Escreve um JSON por caso em `dir` e devolve os caminhos.
    def write(dir, now:)
      dir = Pathname(dir)
      FileUtils.mkdir_p(dir)
      CASES.map do |name, definition|
        dir.join("#{name}.json").tap { |path| path.write(JSON.pretty_generate(bundle(definition, now: now))) }
      end
    end
  end
end
