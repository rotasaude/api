# A linha do catálogo da cidade para um protocolo (ADR 0027; spec 2026-10-05
# §3.2, §6.2; contratos §4.2). O corpo é a linha INTEIRA. A restrição só usa
# profile.age, profile.sex e citizen.neighborhood_id e soma com E à
# elegibilidade assinada (Triages::Offer): a cidade restringe, nunca amplia.
# Quem pode e o step-up ficam no controller. Evento só quando muda.
# Reasons: :unknown_protocol, :invalid_enabled, :invalid_position,
# :invalid_period, :invalid_restriction, :invalid_suggestion_only.
# `suggestion_only` é a única chave opcional: ausente mantém o valor gravado
# (o dashboard anterior a ela não a manda).
module Triages
  module SetOffer
    POSITIONS = (1..10_000)
    MAX_RESTRICTION_BYTES = 4096
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    def call(protocol_name:, attributes:, by:)
      name = protocol_name.to_s
      return Result.fail(:unknown_protocol) unless ProtocolDefinition.exists?(name: name)

      changes = validate(attributes)
      return changes if changes.is_a?(Result)

      save(name, changes, by)
    end

    def validate(attributes)
      enabled = attributes["enabled"]
      return Result.fail(:invalid_enabled) unless [ true, false ].include?(enabled)

      position = attributes["position"]
      return Result.fail(:invalid_position) unless position.is_a?(Integer) && POSITIONS.cover?(position)

      from = date(attributes["available_from"])
      until_on = date(attributes["available_until"])
      return Result.fail(:invalid_period) if [ from, until_on ].include?(:invalid)
      return Result.fail(:invalid_period) if from && until_on && until_on < from

      restriction = attributes["restriction"]
      return Result.fail(:invalid_restriction) unless restriction_valid?(restriction)

      changes = { enabled: enabled, position: position, restriction: restriction, available_from: from,
                  available_until: until_on }
      return changes unless attributes.key?("suggestion_only")
      return Result.fail(:invalid_suggestion_only) unless [ true, false ].include?(attributes["suggestion_only"])

      changes.merge(suggestion_only: attributes["suggestion_only"])
    end

    def date(raw)
      return nil if raw.nil?
      return :invalid unless raw.is_a?(String) && raw.match?(DATE)

      Date.iso8601(raw)
    rescue Date::Error
      :invalid
    end

    def restriction_valid?(restriction)
      return true if restriction.nil?
      return false unless restriction.is_a?(Hash) && restriction.to_json.bytesize <= MAX_RESTRICTION_BYTES

      Protocols::Validation::Condition.errors(restriction, {}, variables: Protocols::Validation::Offer::RESTRICTION).empty?
    end

    def save(name, changes, by, attempt: 1)
      ApplicationRecord.transaction do
        row = TriageOffer.lock.find_by(protocol_name: name) || TriageOffer.new(protocol_name: name)
        row.assign_attributes(changes)
        if row.new_record? || row.changed?
          row.updated_by_user = by
          row.save!
          DomainEvents.publish("triage_offer.changed", protocol_name: name, user_id: by.id)
        end
      end
      Result.ok(offer: TriageOffer.find_by!(protocol_name: name))
    rescue ActiveRecord::RecordNotUnique
      # Duas criações ao mesmo tempo: a segunda acha a linha da primeira.
      raise if attempt > 1

      save(name, changes, by, attempt: attempt + 1)
    end
  end
end
