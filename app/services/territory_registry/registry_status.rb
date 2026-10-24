# Validade e quem falta cadastrar por equipe e microárea (módulo 24a, F-24.6;
# contrato §6; §14 L5, L12, L19). População = CareLines::TeamPopulation.members
# (pacientes da equipe — com o cadastro, que vence a consulta — e pares
# validados sem paciente, um por CPF) ∪ cadastros ativos da equipe, menos os
# óbitos (CareLines::Facts.deceased). Com microárea, só os cadastros dela
# (quem não tem cadastro não tem microárea). Situação: a do cadastro ativo na
# equipe (Validity) ou missing. Em tuplas (pluck), sem objeto por pessoa e
# sem lista de ids no texto do SQL (revisão final, M2: ESF até 4.000): sem
# identificador = IS NULL no banco; decifra só a recusa do cadastro (cifra
# não determinística) e o CPF dos pares (um por CPF); nome e idade só da
# página. Ordem por person_ref decrescente, paginada em Ruby sobre as
# tuplas; o cursor é o person_ref da última pessoa (R9). Sem trilha aqui: a
# lista nominal grava a sua no controller, a contagem não grava.
module TerritoryRegistry
  module RegistryStatus
    COUNTED = %w[valid due_soon expired missing missing_identifier].freeze
    # refused aparece na lista (filtro), fora das contagens; exited nunca é população.
    LISTED = (COUNTED + %w[refused]).freeze
    PERSON_REF = /\A(?:patient|citizen):\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    Entry = Data.define(:ref, :id, :kind, :registration_id, :status)

    module_function

    # { valid:, due_soon:, expired:, missing:, missing_identifier: }.
    def count(team:, today:, micro_area: nil)
      tally = entries(team, micro_area, today).map(&:status).tally
      COUNTED.to_h { |status| [ status.to_sym, tally.fetch(status, 0) ] }
    end

    # { people: [<person_row>], next_before: person_ref | nil }.
    def page(team:, limit:, today:, micro_area: nil, status: nil, before: nil)
      rows = entries(team, micro_area, today)
      rows = rows.select { |row| row.status == status } if status
      rows = rows.select { |row| row.ref < before } if before
      rows = rows.max_by(limit + 1, &:ref)
      shown = rows.first(limit)
      { people: person_rows(shown, today), next_before: rows.size > limit ? shown.last.ref : nil }
    end

    # Cadastros ativos da equipe em tuplas: [paciente, cadastro, gravação,
    # recusa (decifrada), identificado (CPF ou CNS, IS NOT NULL no banco)].
    def entries(team, micro_area, today)
      scope = IndividualRegistration.active_registrations.where(team_id: team.id).joins(:patient)
      scope = scope.where(micro_area_id: micro_area.id) if micro_area
      registrations = scope.pluck(:patient_id, :id, :registered_at, :refused,
                                  Arel.sql("patients.cpf IS NOT NULL OR patients.cns IS NOT NULL"))
                           .to_h { |patient_id, *rest| [ patient_id, rest ] }
      patient_ids, citizen_ids = population(team, micro_area, registrations.keys)
      patient_ids -= CareLines::Facts.deceased(patient_ids).to_a
      patients = patient_ids.map do |id|
        registration_id, registered_at, refused, identified = registrations[id]
        status = if registration_id
                   Validity.status_of(registered_at: registered_at, refused: refused == "true", identified: identified, today: today)
                 else
                   "missing"
                 end
        Entry.new(ref: "patient:#{id}", id: id, kind: :patient, registration_id: registration_id, status: status)
      end
      patients + citizen_ids.map { |id| Entry.new(ref: "citizen:#{id}", id: id, kind: :citizen, registration_id: nil, status: "missing") }
    end
    private_class_method :entries

    def population(team, micro_area, registered_ids)
      return [ registered_ids, [] ] if micro_area

      members = CareLines::TeamPopulation.members(team: team)
      [ members[:patient_ids] | registered_ids, CareLines::Facts.one_per_cpf(members[:citizens]).to_a ]
    end
    private_class_method :population

    def person_rows(entries, today)
      patients = Patient.where(id: entries.select { |e| e.kind == :patient }.map(&:id)).index_by(&:id)
      citizens = Citizen.where(id: entries.select { |e| e.kind == :citizen }.map(&:id)).index_by(&:id)
      registrations = IndividualRegistration.includes(:micro_area).where(id: entries.filter_map(&:registration_id)).index_by(&:id)
      entries.map do |entry|
        person = entry.kind == :patient ? patients.fetch(entry.id) : citizens.fetch(entry.id)
        Json.person_row(person, status: entry.status, registration: registrations[entry.registration_id], today: today)
      end
    end
    private_class_method :person_rows
  end
end
