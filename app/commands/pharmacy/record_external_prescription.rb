# Receita externa digitada na farmácia (ADR 0045; plano do api, Task 10;
# contrato §7, H3, H6, H12): a receita de fora da rede, com o prescritor, a data
# e os itens do catálogo. Quem dispensa é `pharmacist` ou `pharmacy_assistant` do
# local `unit`; o item CONTROLADO só o farmacêutico registra (403 sozinho).
#
# Paciente: exatamente um de `patient_id` (existente) | `new_patient` (a forma do
# 24a: Patients::CreateTyped, as recusas com o path `new_patient.<campo>`).
# `new_patient` com nome + nascimento de paciente já gravado → 409
# duplicate_suspected, salvo `duplicates_reviewed: true` (conferido sob o mesmo
# lock consultivo da match_key do 24a e do 25). Paciente criado e receita na MESMA
# transação: qualquer recusa ou falha desfaz o paciente.
#
# Todas as recusas voltam de uma vez (H8/H12): `error`/`path` do primeiro e
# `problems: [ { path, error } ]` com todos, na ordem paciente → prescritor →
# data → itens → número da notificação. Nada é gravado se houver uma. O 409 de
# duplicado e o de CPF/CNS tomado só aparecem sem recusa de campo (precisam de
# banco e travas). O 403 de papel vem sozinho, antes de qualquer lista.
#
# Regras (H3, Desvio 8):
#  - prescritor: `name` 3..120, `council` em COUNCILS (CRM, CRO, COREN),
#    `council_state` UF maiúscula, `council_number` só dígitos (até 10);
#  - `issued_on`: AAAA-MM-DD, não futura. `prescription_expired` (path
#    `issued_on`) SÓ quando TODOS os itens já nascem vencidos (item controlado:
#    30 dias fixos; senão o prazo da cidade, comum ou contínuo). Um item inválido
#    conta com o MAIOR prazo possível (o contínuo da cidade): só se afirma o
#    vencimento quando ele vale para qualquer item;
#  - itens 1..20: `catalog_item_id` ativo no catálogo, `quantity` String positiva
#    até 99999.99, `quantity_unit` 1..30, `dosage_instructions` 3..500,
#    `continuous` booleano (ausente = falso);
#  - `notification_number` (NOTIFICATION_NUMBER) obrigatório com item das listas
#    A/B (`notification_required`); com item só de outras listas é opcional e,
#    vindo, tem de ter o formato;
#  - `retention_required` NÃO é gravado nem aceito: quem digita não marca nada. É
#    do catálogo (antimicrobiano ou controlado) e sai na <prescription_view>.
#
# Ordem de travas: local (FOR SHARE) → match_key do paciente digitado → paciente
# (CPF) → receita. Nenhum estoque é escrito aqui (sem lote). O catálogo da
# plataforma é lido FORA da transação, pelo controlador (`catalog`).
#
# Evento `external_prescription.recorded` só com ids (external_prescription_id,
# user_id) e a trilha clinical_record.viewed da pessoa, na mesma transação. Nada
# pessoal em Result, evento, erro nem inspect.
module Pharmacy
  module RecordExternalPrescription
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    PRESCRIBER_NAME = (3..Catalog::NAME_MAX)

    # Item já validado. Posologia e medicamento: nada em inspect, to_s,
    # pretty_print nem as_json.
    Row = Data.define(:index, :entry, :quantity, :quantity_unit, :dosage_instructions, :continuous) do
      def inspect = "#<Pharmacy::RecordExternalPrescription::Row #{index}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "index" => index }
    end

    module_function

    # -> Result.ok(external_prescription:, patient:) |
    # fail(:controlled_requires_pharmacist) |
    # fail(<primeiro erro>, details: { path:, problems: [ { path:, error: } ] }) |
    # fail(:duplicate_suspected | :cpf_taken | :cns_taken | :location_inactive, ...)
    def call(location:, patient_id:, new_patient:, prescriber:, issued_on:, notification_number:, items:, by:, role:, catalog:, today:,
             duplicates_reviewed: false, settings: Settings.current)
      problems = []
      person, found = parse_person(patient_id, new_patient, duplicates_reviewed)
      problems.concat(found)
      writer, found = parse_prescriber(prescriber)
      problems.concat(found)
      date, found = parse_issued_on(issued_on, today)
      problems.concat(found)
      rows, entries, found = parse_items(items, catalog)
      item_problems = found

      # 403 de papel: um item controlado do catálogo, qualquer que seja o resto.
      return Result.fail(:controlled_requires_pharmacist) if role != "pharmacist" && entries.any? { |entry| entry.controlled == true }

      problems.concat(expiry_problems(date, rows, settings: settings, today: today))
      problems.concat(item_problems)
      number, found = parse_notification(notification_number, entries)
      problems.concat(found)
      return failure(problems) if problems.any?

      persist(location: location, person: person, writer: writer, date: date, number: number, rows: rows, by: by)
    end

    # ---- validação (sem gravar, fora da transação) -------------------------

    # -> [ { patient_id: } | { new_patient:, reviewed: }, [ problem ] ]
    def parse_person(patient_id, new_patient, duplicates_reviewed)
      return [ nil, [ problem("patient_id", :invalid_request) ] ] if !patient_id.nil? && !new_patient.nil?
      return [ nil, [ problem("patient_id", :invalid_request) ] ] if patient_id.nil? && new_patient.nil?

      if patient_id
        return [ nil, [ problem("patient_id", :invalid_request) ] ] unless patient_id.is_a?(String) && patient_id.match?(UUID) && Patient.exists?(id: patient_id)

        return [ { patient_id: patient_id }, [] ]
      end

      return [ nil, [ problem("new_patient", :invalid_request) ] ] unless new_patient.is_a?(Hash)

      found = []
      found.concat(typed_problems(Patients::CreateTyped.check(new_patient)))
      found << problem("duplicates_reviewed", :invalid_request) unless [ true, false ].include?(duplicates_reviewed)
      [ found.empty? ? { new_patient: new_patient, reviewed: duplicates_reviewed } : nil, found ]
    end

    # A recusa de forma do CreateTyped com o path do corpo (new_patient.*).
    def typed_problems(parsed)
      return [] if parsed.ok?

      case parsed.reason
      when :invalid_cpf then [ problem("new_patient.cpf", :invalid_cpf) ]
      when :invalid_cns then [ problem("new_patient.cns", :invalid_cns) ]
      when :cpf_or_reason_required then [ problem("new_patient.no_cpf_reason", :cpf_or_reason_required) ]
      else [ problem(parsed.details.fetch(:path, "new_patient"), parsed.reason) ]
      end
    end

    # -> [ { name:, council:, council_state:, council_number: } | nil, [ problem ] ]
    def parse_prescriber(raw)
      return [ nil, [ problem("prescriber", :invalid_request) ] ] unless raw.is_a?(Hash)

      name = raw["name"].is_a?(String) ? raw["name"].strip : nil
      found = []
      found << problem("prescriber.name", :invalid_request) unless name && PRESCRIBER_NAME.cover?(name.length)
      found << problem("prescriber.council", :invalid_request) unless Catalog::COUNCILS.include?(raw["council"])
      found << problem("prescriber.council_state", :invalid_request) unless raw["council_state"].is_a?(String) && raw["council_state"].match?(Catalog::UF)
      found << problem("prescriber.council_number", :invalid_request) unless raw["council_number"].is_a?(String) && raw["council_number"].match?(Catalog::COUNCIL_NUMBER)
      [ found.empty? ? { name: name, council: raw["council"], council_state: raw["council_state"], council_number: raw["council_number"] } : nil, found ]
    end

    # -> [ Date | nil, [ problem ] ]
    def parse_issued_on(raw, today)
      date = parse_date(raw)
      return [ nil, [ problem("issued_on", :invalid_request) ] ] if date.nil? || date > today

      [ date, [] ]
    end

    def parse_date(raw)
      return nil unless raw.is_a?(String) && raw.match?(ISO_DATE)

      Date.iso8601(raw)
    rescue Date::Error
      nil
    end

    # -> [ [ Row | nil por item ], [ MedicationCatalogItem dos itens achados ], [ problem ] ]
    # `entries` vale mesmo para a linha com outro campo inválido: o papel e o
    # número da notificação dependem do medicamento, não do resto da linha.
    def parse_items(items, catalog)
      return [ [], [], [ problem("items", :invalid_request) ] ] unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_EXTERNAL_ITEMS)

      rows = []
      entries = []
      found = []
      items.each_with_index do |raw, index|
        row, entry, row_problems = raw.is_a?(Hash) ? parse_item(raw, index, catalog) : [ nil, nil, [ problem("items[#{index}]", :invalid_request) ] ]
        rows << row
        entries << entry if entry
        found.concat(row_problems)
      end
      [ rows, entries, found ]
    end

    # -> [ Row | nil, MedicationCatalogItem | nil, [ problem ] ]
    def parse_item(raw, index, catalog)
      prefix = "items[#{index}]"
      problems = []
      entry = raw["catalog_item_id"].is_a?(String) ? catalog[raw["catalog_item_id"]] : nil
      entry = nil unless entry&.status == "active"
      problems << problem("#{prefix}.catalog_item_id", :invalid_item) unless entry

      quantity = Quantity.parse(raw["quantity"])
      problems << problem("#{prefix}.quantity", :invalid_quantity) unless quantity

      unit = raw["quantity_unit"].is_a?(String) ? raw["quantity_unit"].strip : nil
      problems << problem("#{prefix}.quantity_unit", :invalid_request) unless unit && unit.length.between?(1, Catalog::QUANTITY_UNIT_MAX)

      dosage = raw["dosage_instructions"].is_a?(String) ? raw["dosage_instructions"].strip : nil
      problems << problem("#{prefix}.dosage_instructions", :invalid_request) unless dosage && Catalog::DOSAGE.cover?(dosage.length)

      continuous = raw.fetch("continuous", false)
      problems << problem("#{prefix}.continuous", :invalid_request) unless [ true, false ].include?(continuous)

      return [ nil, entry, problems ] if problems.any?

      [ Row.new(index: index, entry: entry, quantity: quantity, quantity_unit: unit, dosage_instructions: dosage, continuous: continuous), entry, [] ]
    end

    # `prescription_expired` só quando TODOS os itens nascem vencidos. Linha
    # inválida vale o maior prazo possível; sem lista de itens, nada a afirmar.
    def expiry_problems(date, rows, settings:, today:)
      return [] if date.nil? || rows.empty?

      latest = date + [ settings.common_validity_days, settings.continuous_validity_days ].max
      expired = rows.all? do |row|
        until_date = if row
                       Validity.item_until(issued_on: date, explicit: nil, continuous: row.continuous, controlled: row.entry.controlled_list.present?,
                                           external: true, settings: settings)
                     else
                       latest
                     end
        Validity.expired?(until_date, today: today)
      end
      expired ? [ problem("issued_on", :prescription_expired) ] : []
    end

    # -> [ String | nil, [ problem ] ]. Lista A/B exige; com outro tipo é opcional.
    def parse_notification(raw, entries)
      required = entries.any? { |entry| Catalog::NOTIFICATION_LISTS.include?(entry.controlled_list) }
      return [ nil, required ? [ problem("notification_number", :notification_required) ] : [] ] if raw.nil? || raw == ""
      return [ nil, [ problem("notification_number", :invalid_request) ] ] unless raw.is_a?(String) && raw.match?(Catalog::NOTIFICATION_NUMBER)

      [ raw, [] ]
    end

    # ---- gravação (com banco, dentro da transação) -------------------------

    def persist(location:, person:, writer:, date:, number:, rows:, by:)
      result = nil
      ExternalPrescription.transaction(requires_new: true) do
        result = write(location: location, person: person, writer: writer, date: date, number: number, rows: rows, by: by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def write(location:, person:, writer:, date:, number:, rows:, by:)
      Ledger.lock_location!(location.id)
      patient = patient_for(person, by)
      return patient if patient.is_a?(Result)

      record = ExternalPrescription.create!(patient: patient, stock_location: location, recorded_by_user: by, prescriber_name: writer[:name],
                                            council: writer[:council], council_state: writer[:council_state],
                                            council_number: writer[:council_number], issued_on: date, notification_number: number)
      rows.each_with_index do |row, index|
        ExternalPrescriptionItem.create!(external_prescription: record, position: index + 1, catalog_item_id: row.entry.id,
                                         catmat_code: row.entry.catmat_code, quantity: row.quantity, quantity_unit: row.quantity_unit,
                                         dosage_instructions: row.dosage_instructions, continuous: row.continuous,
                                         controlled_list: row.entry.controlled_list)
      end
      DomainEvents.publish("external_prescription.recorded", external_prescription_id: record.id, user_id: by.id)
      Trail.person_viewed!(user: by, patient_id: patient.id)
      Result.ok(external_prescription: record, patient: patient)
    rescue Ledger::Inactive
      Result.fail(:location_inactive)
    end

    # -> Patient | Result (a recusa)
    def patient_for(person, by)
      # Sumido entre a validação e a gravação: a mesma recusa (com problems) da validação.
      return Patient.find_by(id: person[:patient_id]) || failure([ problem("patient_id", :invalid_request) ]) if person[:patient_id]

      create_typed(person.fetch(:new_patient), person.fetch(:reviewed), by)
    end

    # A mesma trava do 24a e do 25 (a chave é um hash: nunca nome nem nascimento
    # no SQL), depois o duplicado, depois a criação.
    def create_typed(new_patient, reviewed, by)
      typed = new_patient.to_h.stringify_keys
      key = typed.values_at("full_name", "birth_date").all?(String) && Patients::MatchKey.for(typed["full_name"], typed["birth_date"])
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{match_lock_key(key)})") if key
      return Result.fail(:duplicate_suspected) if !reviewed && duplicate?(typed)

      created = Patients::CreateTyped.call(attrs: typed, by: by)
      return created.payload.fetch(:patient) if created.ok?

      path = { cpf_taken: "new_patient.cpf", cns_taken: "new_patient.cns" }[created.reason]
      Result.fail(created.reason, details: path ? { path: path } : created.details)
    end

    # Possível duplicado pela regra da busca (Patients::Duplicates); com CPF
    # digitado, só candidatos sem CPF (outro CPF é outra pessoa; o mesmo é cpf_taken).
    def duplicate?(typed)
      strings = %w[full_name birth_date mother_name cpf].map { |key| typed[key] }
      return false unless strings.all? { |value| value.nil? || value.is_a?(String) }

      Patients::Duplicates.call(full_name: strings[0], birth_date: strings[1], mother_name: strings[2], limit: 1,
                                only_without_cpf: strings[3].present?).any?
    end

    def match_lock_key(key) = Digest::SHA256.hexdigest("patients:match_key:#{key}")[0, 15].to_i(16)

    # ---- resultado ---------------------------------------------------------

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :parse_person, :typed_problems, :parse_prescriber, :parse_issued_on, :parse_date, :parse_items, :parse_item,
                         :expiry_problems, :parse_notification, :persist, :write, :patient_for, :create_typed, :duplicate?, :match_lock_key,
                         :problem, :failure
  end
end
