# api#43 (ADR 0030; spec 2026-10-07 §5–§6): a fila LEDI deixa de guardar texto
# do PEC. last_error vira last_error_codes ([{ field, code }]); a conversão
# do que existe é feita aqui, com regras congeladas (não chama o app), e o
# texto some. last_attempted_at mede os 90 dias da purga; replaces_outbox_id
# liga a ficha regerada à recusada; o índice único passa a ignorar recusadas.
class LediOutboxErrorCodes < ActiveRecord::Migration[8.1]
  FIELDS = %w[uuidFicha headerTransport profissionalCNS cboCodigo_2002 cnes ine dataAtendimento codigoIbgeMunicipio
              cpfCidadao cnsCidadao cns dataNascimento dtNascimento sexo turno localDeAtendimento localAtendimento
              tipoAtendimento condutas problemasCondicoes ciap medicoes procedimentos dataHoraInicialAtendimento
              dataHoraFinalAtendimento].freeze
  TRANSPORT = [ [ /\AHTTP \d+\z/, "http_error" ], [ /\APEC inacess/, "unreachable" ],
                [ /\Aendereço do PEC inválido\z/, "invalid_url" ], [ /\Alogin no PEC respondeu/, "login_failed" ],
                [ /\Aerro interno \(/, "internal_error" ] ].freeze
  UNKNOWN = [ { "field" => "other", "code" => "unknown" } ].freeze

  # Texto antigo (Ledi::ErrorText.sanitize de "descrição; campo: msg; …") → códigos.
  def self.codes_for(text)
    text = text.to_s.strip
    return [] if text.empty?

    TRANSPORT.each { |pattern, code| return [ { "field" => "transport", "code" => code } ] if text.match?(pattern) }
    codes = text.split("; ").filter_map do |part|
      key, message = part.split(": ", 2)
      next unless message

      field = key.split(/[.\[\]]+/).reverse.find { |segment| FIELDS.include?(segment) }
      field && { "field" => field, "code" => code_for(message) }
    end
    codes.empty? ? UNKNOWN.map(&:dup) : codes.uniq.first(20)
  end

  def self.code_for(message)
    text = I18n.transliterate(message.to_s.downcase)
    return "required" if text.match?(/obrigatori|requerid|ausente/)
    return "not_allowed" if text.match?(/nao (e |eh )?permitid|nao pode|nao aceit/)
    return "invalid" if text.match?(/invalid|incorret|formato/)

    "unknown"
  end

  def up
    add_column :ledi_outbox, :last_error_codes, :jsonb, null: false, default: []
    add_column :ledi_outbox, :last_attempted_at, :datetime
    add_column :ledi_outbox, :replaces_outbox_id, :uuid
    add_foreign_key :ledi_outbox, :ledi_outbox, column: :replaces_outbox_id
    add_index :ledi_outbox, :replaces_outbox_id, unique: true, name: "idx_ledi_outbox_replaces"

    # Sem desligar ledi_outbox_guard: ele recusa todo UPDATE em accepted, e
    # nenhuma accepted precisa de conversão — accept! sempre zerou last_error
    # (o que restasse some com a coluna) e a purga dos 90 dias só olha
    # rejected/failed. Nas demais, os UPDATEs só tocam colunas que o guarda
    # permite. Recusada cujo texto não vira código fica "desconhecido" (o
    # CHECK novo exige código em recusada com conteúdo).
    select_rows("SELECT id, status, last_error FROM ledi_outbox WHERE status <> 'accepted'").each do |id, status, text|
      codes = self.class.codes_for(text)
      codes = UNKNOWN if codes.empty? && status == "rejected"
      next if codes.empty?

      execute "UPDATE ledi_outbox SET last_error_codes = #{quote(codes.to_json)}::jsonb WHERE id = #{quote(id)}"
    end
    execute "UPDATE ledi_outbox SET last_attempted_at = updated_at WHERE attempts > 0 AND status <> 'accepted'"

    remove_check_constraint :ledi_outbox, name: "ck_ledi_outbox_rejected_error"
    remove_column :ledi_outbox, :last_error
    add_check_constraint :ledi_outbox, "jsonb_typeof(last_error_codes) = 'array'::text", name: "ck_ledi_outbox_error_codes"
    add_check_constraint :ledi_outbox,
                         "status::text <> 'rejected'::text OR jsonb_array_length(last_error_codes) > 0 OR payload IS NULL",
                         name: "ck_ledi_outbox_rejected_error"
    remove_index :ledi_outbox, name: "idx_ledi_outbox_source"
    add_index :ledi_outbox, %i[source_type source_id ficha_type], unique: true, name: "idx_ledi_outbox_source",
                                                                  where: "(status)::text <> 'rejected'::text"
    add_index :ledi_outbox, %i[source_type source_id], name: "idx_ledi_outbox_source_lookup"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quote(value) = connection.quote(value)
end
