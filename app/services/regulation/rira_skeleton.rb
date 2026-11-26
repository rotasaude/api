module Regulation
  # Esqueleto do documento RIRA (módulo 26c; Valor 4, `skeleton:<caminho>`):
  # os campos de presença obrigatória (mín. 1) dos quatro perfis do pacote
  # oficial 1.0.0 — o spec os confere contra os StructureDefinitions do
  # fixture — e o mínimo do Bundle `document` (bdl-9, bdl-10).
  # `problems(bundle)` devolve os CAMINHOS ausentes, nunca valores (o Bundle é
  # dado sensível); quem chama prefixa `skeleton:`. Numa lista, todo item
  # precisa do campo.
  #
  # Q23: também as invariantes de severidade error do pacote, por situação,
  # como `<caminho>[<chave>]` (o caminho é o campo ausente ou proibido):
  # app-2/app-3 (start e end), mira-2..12 (datas, realização e executante),
  # mira-13..19 (par de status), ident-4 (o mesmo paciente), ident-1 (CPF/CNS),
  # estab-2 (CNES) e date-1 (Composition.date). Documento com problema não sai.
  module RiraSkeleton
    BUNDLE = %w[type timestamp identifier.system identifier.value].freeze
    RESOURCES = %w[Composition Appointment ServiceRequest Condition].freeze
    REQUIRED = {
      "Composition" => %w[
        status type.coding.system type.coding.code category.coding.system category.coding.code subject date
        author.identifier.system author.identifier.value title event.code.coding.system event.code.coding.code
        event.period.end section.entry.reference
      ],
      "Appointment" => %w[
        status serviceCategory.coding.system serviceCategory.coding.code serviceType.coding.system serviceType.coding.code
        appointmentType.coding.system appointmentType.coding.code basedOn.reference participant.type.coding.system
        participant.type.coding.code participant.actor.identifier.system participant.actor.identifier.value participant.status
      ],
      "ServiceRequest" => %w[
        status intent category.coding.system category.coding.code priority code.coding.system code.coding.code
        subject.identifier.system subject.identifier.value authoredOn requester.identifier.system requester.identifier.value
      ],
      "Condition" => %w[code.coding.system code.coding.code subject.identifier.system subject.identifier.value]
    }.transform_values(&:freeze).freeze
    # Filhos obrigatórios de campos opcionais: valem quando o pai existe.
    NESTED = {
      "Composition" => { "relatesTo" => %w[code targetReference.reference] },
      "Appointment" => { "specialty" => %w[coding.system coding.code], "reasonReference" => %w[reference] },
      "ServiceRequest" => { "performerType" => %w[coding.system coding.code], "performer" => %w[identifier.system identifier.value],
                            "reasonReference" => %w[reference] }
    }.freeze

    # Invariantes por situação (Composition.event): app-3 aceita sem datas só
    # estes status do Appointment.
    UNDATED_APPOINTMENT = %w[proposed cancelled waitlist].freeze
    DATED = { "booked" => "mira-5", "attended" => "mira-7", "absence" => "mira-10" }.freeze
    PERFORMER = { "booked" => "mira-6", "attended" => "mira-8", "absence" => "mira-11" }.freeze
    OCCURRENCE = { "attended" => "mira-9", "absence" => "mira-12" }.freeze
    STATUS_PAIR = { "pending" => "mira-13", "returned-to-requester" => "mira-14", "booked" => "mira-15", "attended" => "mira-16",
                    "cancelled" => "mira-17", "absence" => "mira-18", "excluded" => "mira-19" }.freeze
    PERSON = /\A(?!(\d)\1{10})\d{11}\z|\A(?!(\d)\2{14})[125789]\d{14}\z/
    ESTABLISHMENT = /\A(?!(\d)\1{6})\d{7}\z/
    DOCUMENT_DATE = /\A(200[1-9]|20[1-9]\d|[2-9]\d{3})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\z/

    module_function

    # -> [String] (caminhos ausentes; [] = esqueleto completo)
    def problems(bundle)
      return [ "Bundle" ] unless bundle.is_a?(Hash)

      problems = []
      problems << "Bundle.type" unless bundle["type"] == "document"
      problems.concat(missing("Bundle", bundle, BUNDLE - %w[type]))
      entries = Array(bundle["entry"])
      resources = entries.map { |entry| entry.is_a?(Hash) ? entry["resource"] : nil }
      RESOURCES.each_with_index do |type, index|
        resource = resources[index]
        next problems << "Bundle.entry.#{type}" unless resource.is_a?(Hash) && resource["resourceType"] == type

        problems.concat(missing(type, resource, REQUIRED.fetch(type)))
        NESTED.fetch(type, {}).each do |parent, paths|
          problems.concat(missing("#{type}.#{parent}", resource[parent], paths)) unless blank?(resource[parent])
        end
      end
      return problems if problems.any? { |path| path.start_with?("Bundle.entry") }

      problems.concat(references(entries, resources))
      problems.concat(invariants(*resources.first(4)))
    end

    def invariants(composition, appointment, request, condition)
      code = composition.dig("event", 0, "code", 0, "coding", 0, "code")
      out = dates(code, appointment)
      out << "ServiceRequest.occurrenceDateTime[mira-3]" if code == "pending" && !blank?(request["occurrenceDateTime"])
      out << "ServiceRequest.performer[mira-4]" if code == "pending" && !blank?(request["performer"])
      out << "ServiceRequest.performer[#{PERFORMER[code]}]" if PERFORMER[code] && blank?(request["performer"])
      out << "ServiceRequest.occurrenceDateTime[#{OCCURRENCE[code]}]" if OCCURRENCE[code] && blank?(request["occurrenceDateTime"])
      out.concat(status_pair(code, appointment, request))
      out.concat(identities(composition, appointment, request, condition))
      out << "Composition.date[date-1]" unless composition["date"].is_a?(String) && composition["date"].match?(DOCUMENT_DATE)
      out
    end

    def dates(code, appointment)
      start, finish = %w[start end].map { |field| !blank?(appointment[field]) }
      out = []
      out << "Appointment.#{start ? 'end' : 'start'}[app-2]" if start != finish
      unless (start && finish) || UNDATED_APPOINTMENT.include?(appointment["status"])
        out.concat({ "start" => start, "end" => finish }.reject { |_, present| present }.keys.map { |field| "Appointment.#{field}[app-3]" })
      end
      if code == "pending"
        out.concat({ "start" => start, "end" => finish }.select { |_, present| present }.keys.map { |field| "Appointment.#{field}[mira-2]" })
      end
      if (key = DATED[code])
        out.concat({ "start" => start, "end" => finish }.reject { |_, present| present }.keys.map { |field| "Appointment.#{field}[#{key}]" })
      end
      out
    end

    def status_pair(code, appointment, request)
      key = STATUS_PAIR[code]
      return [ "Composition.event.code.coding.code[binding]" ] unless key

      appointment_status, request_status = RndsCatalog::STATUS_RELATION.fetch(code)
      out = []
      out << "Appointment.status[#{key}]" unless appointment["status"] == appointment_status
      out << "ServiceRequest.status[#{key}]" unless request["status"] == request_status
      out
    end

    def identities(composition, appointment, request, condition)
      people = { "Composition.subject.identifier.value" => composition.dig("subject", "identifier", "value"),
                 "Appointment.participant.actor.identifier.value" => appointment.dig("participant", 0, "actor", "identifier", "value"),
                 "ServiceRequest.subject.identifier.value" => request.dig("subject", "identifier", "value") }
      patient = people.values.first
      others = people.values.drop(1) + [ condition.dig("subject", "identifier", "value") ]
      out = []
      out << "Composition.subject.identifier.value[ident-4]" if others.any? { |value| value != patient }
      people.each { |path, value| out << "#{path}[ident-1]" if value.is_a?(String) && !value.match?(PERSON) }
      { "Composition.author.identifier.value" => Array(composition["author"]).map { |a| a.dig("identifier", "value") },
        "ServiceRequest.requester.identifier.value" => [ request.dig("requester", "identifier", "value") ],
        "ServiceRequest.performer.identifier.value" => Array(request["performer"]).map { |p| p.dig("identifier", "value") } }
        .each { |path, values| out << "#{path}[estab-2]" if values.any? { |v| v.is_a?(String) && !v.match?(ESTABLISHMENT) } }
      out
    end

    def missing(prefix, node, paths)
      paths.reject { |path| present?(node, path.split(".")) }.map { |path| "#{prefix}.#{path}" }
    end

    # Cada nó do caminho tem o filho (numa lista, todos os itens).
    def present?(node, keys)
      return !blank?(node) if keys.empty?

      nodes = node.is_a?(Array) ? node : [ node ]
      nodes.any? && nodes.all? { |item| item.is_a?(Hash) && !blank?(item[keys.first]) && present?(item[keys.first], keys.drop(1)) }
    end

    # As referências internas apontam a entrada certa.
    def references(entries, resources)
      urls = entries.map { |entry| entry["fullUrl"] }
      expected = { "Composition.section.entry.reference" => [ resources[0].dig("section", 0, "entry", 0, "reference"), urls[1] ],
                   "Appointment.basedOn.reference" => [ resources[1].dig("basedOn", 0, "reference"), urls[2] ] }
      expected.filter_map { |path, (found, url)| path if url.blank? || found != url }
    end

    def blank?(value) = value.nil? || value == "" || (value.respond_to?(:empty?) && value.empty?)
    private_class_method :missing, :present?, :references, :invariants, :dates, :status_pair, :identities, :blank?
  end
end
