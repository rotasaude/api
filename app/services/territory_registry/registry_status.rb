# Validade e quem falta cadastrar por equipe e microárea (módulo 24a, F-24.6;
# contrato §6; §14 L5, L12, L19). População = CareLines::TeamPopulation.members
# (pacientes da equipe — com o cadastro, que vence a consulta — e pares
# validados sem paciente, um por CPF) ∪ cadastros ativos da equipe, menos os
# óbitos (CareLines::Facts.deceased). Com microárea, só os cadastros dela
# (quem não tem cadastro não tem microárea). Situação: a do cadastro ativo na
# equipe (Validity) ou missing. A situação de todos sai sem decifrar nome,
# CPF nem CNS (sem identificador = IS NULL no banco; só a recusa, cifrada, é
# lida); nome e idade só da página. Ordem por person_ref decrescente; o
# cursor é o person_ref da última pessoa (R9). Sem trilha aqui: a lista
# nominal grava a sua no controller, a contagem não grava.
module TerritoryRegistry
  module RegistryStatus
    COUNTED = %w[valid due_soon expired missing missing_identifier].freeze
    # refused aparece na lista (filtro), fora das contagens; exited nunca é população.
    LISTED = (COUNTED + %w[refused]).freeze
    PERSON_REF = /\A(?:patient|citizen):\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    Entry = Data.define(:ref, :id, :kind, :registration, :status)

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

    def entries(team, micro_area, today)
      scope = IndividualRegistration.active_registrations.where(team_id: team.id)
      scope = scope.where(micro_area_id: micro_area.id) if micro_area
      registrations = scope.to_a.index_by(&:patient_id)
      patient_ids, citizen_ids = population(team, micro_area, registrations.keys)
      patient_ids -= CareLines::Facts.deceased(patient_ids).to_a
      unidentified = unidentified_ids(registrations.keys)
      patients = patient_ids.map do |id|
        registration = registrations[id]
        status = registration ? Validity.status(registration, today: today, identified: !unidentified.include?(id)) : "missing"
        Entry.new(ref: "patient:#{id}", id: id, kind: :patient, registration: registration, status: status)
      end
      patients + citizen_ids.map { |id| Entry.new(ref: "citizen:#{id}", id: id, kind: :citizen, registration: nil, status: "missing") }
    end
    private_class_method :entries

    def population(team, micro_area, registered_ids)
      return [ registered_ids, [] ] if micro_area

      members = CareLines::TeamPopulation.members(team: team)
      citizens = members[:citizen_ids].empty? ? [] : Citizen.where(id: members[:citizen_ids]).to_a
      [ members[:patient_ids] | registered_ids, CareLines::Facts.one_per_cpf(citizens).to_a ]
    end
    private_class_method :population

    # Pacientes sem CPF e sem CNS (L5), sem decifrar: nulo continua nulo na cifra.
    def unidentified_ids(patient_ids)
      return Set.new if patient_ids.empty?

      Patient.where(id: patient_ids).where("patients.cpf IS NULL AND patients.cns IS NULL").pluck(:id).to_set
    end
    private_class_method :unidentified_ids

    def person_rows(entries, today)
      patients = Patient.where(id: entries.select { |e| e.kind == :patient }.map(&:id)).index_by(&:id)
      citizens = Citizen.where(id: entries.select { |e| e.kind == :citizen }.map(&:id)).index_by(&:id)
      registrations = entries.filter_map(&:registration)
      ActiveRecord::Associations::Preloader.new(records: registrations, associations: :micro_area).call
      entries.map do |entry|
        person = entry.kind == :patient ? patients.fetch(entry.id) : citizens.fetch(entry.id)
        Json.person_row(person, status: entry.status, registration: entry.registration, today: today)
      end
    end
    private_class_method :person_rows
  end
end
