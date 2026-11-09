# Fusão do paciente provisório no paciente real (ADR 0050, R4; plano, Desvios
# 5 e 6; contrato §14 Q5, Q17, Q21). Tudo que tem o patient_id do provisório
# nasceu do único encontro dele.
#
# - TABLES mudam de dono: `UPDATE <tabela> SET patient_id = real` sob a marca
#   rota.patient_merge (os guardas aceitam SÓ a troca de patient_id do
#   provisório para o merged_into_id gravado nele — rota_patient_merge_ok).
#   Nunca regrava coluna cifrada nem `version`.
# - KEPT ficam com o provisório: as trilhas são a verdade de quem leu o quê.
# - Linha que bateria numa chave única do real (mesmo problema ou medicamento
#   ativo, walk_in aberto na mesma unidade, notificação aberta da mesma
#   doença, qualquer índice único com patient_id) fica com o provisório e
#   conta em `kept_duplicates`; detectada ANTES do UPDATE, pelas colunas e o
#   predicado do próprio índice.
# - Qualquer outra tabela com linha do provisório (blocking_tables) recusa a
#   fusão inteira: merge_blocked, nada muda.
#
# Chame dentro da transação de quem chama, com os dois pacientes travados (o
# Urgency::Identify). Nada da pessoa sai daqui: só nomes de tabela e contagens.
module Urgency
  module Merge
    TABLES = %w[attendances consultations clinical_documents exam_orders exam_results lab_requisitions disease_notifications
                regulation_requests dispensations external_prescriptions performed_procedures patient_problems
                patient_medications].freeze
    KEPT = %w[clinical_record_openings clinical_record_administrative_reads patient_profile_divergences].freeze
    MARKER = "rota.patient_merge".freeze

    class UnsupportedUniqueKey < StandardError; end

    module_function

    # -> Result.ok(moved: { table => Integer }, kept_duplicates: { table => Integer }) | Result.fail(:merge_blocked)
    def call(provisional:, into:)
      return Result.fail(:merge_blocked) if blocking_tables.any? { |table| rows?(table, provisional.id) }

      kept = TABLES.to_h { |table| [ table, colliding_ids(table, provisional.id, into.id) ] }
      provisional.update!(merged_into: into)
      moved = with_marker { TABLES.to_h { |table| [ table, move(table, provisional.id, into.id, kept[table]) ] } }
      Result.ok(moved: moved.select { |_, count| count.positive? },
                kept_duplicates: kept.transform_values(&:size).select { |_, count| count.positive? })
    end

    # As tabelas da cidade com coluna patient_id que não estão em TABLES nem em
    # KEPT: uma linha do provisório ali recusa a fusão. Tabela nova nasce aqui.
    def blocking_tables
      ApplicationRecord.connection.select_values(<<~SQL).sort - TABLES - KEPT - %w[patients]
        SELECT c.table_name FROM information_schema.columns c
        JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = current_schema() AND c.column_name = 'patient_id' AND t.table_type = 'BASE TABLE'
      SQL
    end

    # Os índices únicos (não primários) da tabela que contêm patient_id:
    # [{ name:, columns: [..], predicate: "sql" | nil }]. Índice com expressão
    # não se compara por coluna: levanta (a spec de arquitetura impede).
    def unique_keys(table)
      connection = ApplicationRecord.connection
      rows = connection.select_all(<<~SQL).to_a
        SELECT i.relname AS name, pg_get_expr(ix.indpred, ix.indrelid) AS predicate, ix.indexprs IS NOT NULL AS expressions,
               array_to_json(ARRAY(SELECT a.attname::text FROM unnest(ix.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
                                   JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum ORDER BY k.ord)) AS columns
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = current_schema()
        WHERE t.relname = #{connection.quote(table)} AND ix.indisunique AND NOT ix.indisprimary
      SQL
      rows.filter_map do |row|
        columns = JSON.parse(row["columns"])
        next unless columns.include?("patient_id") || row["expressions"]
        raise UnsupportedUniqueKey, "#{table}: #{row['name']}" if row["expressions"]

        { name: row["name"], columns: columns, predicate: row["predicate"] }
      end
    end

    # A marca no padrão de Consultation.with_draft_admin: savepoint próprio e
    # SET LOCAL; no sucesso volta a 'off' (o SET LOCAL sobreviveria ao RELEASE
    # até o fim da transação de fora); na falha o ROLLBACK TO SAVEPOINT desfaz.
    def with_marker
      connection = ApplicationRecord.connection
      ApplicationRecord.transaction(requires_new: true) do
        connection.execute("SET LOCAL #{MARKER} = 'on'")
        failed = false
        begin
          yield
        rescue Exception # qualquer saída por erro (só marca e relança)
          failed = true
          raise
        ensure
          connection.execute("SET LOCAL #{MARKER} = 'off'") unless failed
        end
      end
    end

    def rows?(table, patient_id)
      connection = ApplicationRecord.connection
      connection.select_value("SELECT 1 FROM #{connection.quote_table_name(table)} WHERE patient_id = #{connection.quote(patient_id)} LIMIT 1").present?
    end

    # Ids das linhas do provisório que bateriam numa chave única do real: as
    # mesmas colunas (fora patient_id) e o mesmo predicado do índice dos dois
    # lados. Sem outra coluna, basta o real ter uma linha no predicado.
    def colliding_ids(table, from_id, into_id)
      connection = ApplicationRecord.connection
      quoted = connection.quote_table_name(table)
      unique_keys(table).flat_map do |key|
        columns = (key[:columns] - %w[patient_id]).map { |column| connection.quote_column_name(column) }.join(", ")
        predicate = key[:predicate] ? "AND (#{key[:predicate]})" : ""
        real_rows = "SELECT #{columns.presence || 1} FROM #{quoted} WHERE patient_id = #{connection.quote(into_id)} #{predicate}"
        match = columns.present? ? "(#{columns}) IN (#{real_rows})" : "EXISTS (#{real_rows})"
        connection.select_values("SELECT id FROM #{quoted} WHERE patient_id = #{connection.quote(from_id)} #{predicate} AND #{match}")
      end.uniq
    end

    def move(table, from_id, into_id, kept_ids)
      connection = ApplicationRecord.connection
      kept = kept_ids.any? ? "AND id NOT IN (#{kept_ids.map { |id| connection.quote(id) }.join(', ')})" : ""
      connection.exec_update("UPDATE #{connection.quote_table_name(table)} SET patient_id = #{connection.quote(into_id)} " \
                             "WHERE patient_id = #{connection.quote(from_id)} #{kept}")
    end
    private_class_method :rows?, :colliding_ids, :move
  end
end
