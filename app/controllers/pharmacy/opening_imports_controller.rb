# Saldo inicial pela planilha conferida (módulo 27b, Task 14; contrato §5;
# Q11, Q19, Q20; R15, R18, R23, R24, R27). REST na cidade, sessão do dashboard.
#
#   GET  /pharmacy/opening_imports/template.csv   o cabeçalho da planilha
#   GET  /pharmacy/opening_imports?before=&limit= a lista, a mais nova primeiro
#   POST /pharmacy/opening_imports                { file_base64 } → 201 <import>
#   GET  /pharmacy/opening_imports/:id?before=&limit=&status= <import> com as linhas
#   POST /pharmacy/opening_imports/:id/apply      { expected_version } com step-up
#   POST /pharmacy/opening_imports/:id/revert     { expected_version } com step-up
#   POST /pharmacy/opening_imports/:id/discard    { expected_version }
#
# Quem: `municipal_admin` ou o `stock_keeper` do central
# (`Pharmacy::Access.central_keeper?`); outro → 403 `missing_role`. Exige só o
# estoque de algum domínio utilizável (`require_stock_feature!`), nunca o
# `bnafar` (Q19). Os interruptores (domínios utilizáveis, R24; domínios com o
# envio ligado, Q26) são lidos AQUI, fora da transação da cidade.
#
# O arquivo chega em base64 num corpo JSON (o 415 `json_required` é da
# Authentication). O tamanho do corpo (MAX_BODY_BYTES ≈ 5 MB decodificados
# em base64 + envelope; `Content-Length` primeiro, depois o corpo lido) dá 413
# `file_too_large`, mas NÃO antes da leitura: o Rails já leu e interpretou o
# corpo para os parâmetros filtrados do log antes da ação. O teto que protege
# a memória é o do proxy/Puma (infra), não este. Nenhuma resposta traz o arquivo, o hash dele nem o
# `file_data`. As linhas paginam pela ordem da planilha (`before` é o cursor
# opaco de continuação, `next_before` na resposta).
module Pharmacy
  class OpeningImportsController < BaseController
    NO_NAME = "—".freeze
    # 4 × ⌈5 MB / 3⌉ de base64 e folga para o envelope JSON.
    MAX_BASE64_BYTES = ((OpeningImports::Reader::MAX_BYTES + 2) / 3) * 4
    MAX_BODY_BYTES = MAX_BASE64_BYTES + 1_024
    ROW_COLUMNS = OpeningImports::Reader::COLUMNS
    ROW_STATUSES = OpeningImportRow::STATUSES

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!
    before_action :require_importer!
    before_action :load_import, only: %i[show apply revert discard]

    def template
      send_data "#{OpeningImports::Reader::HEADER.join(';')}\r\n", type: "text/csv; charset=utf-8", filename: "saldo-inicial.csv",
                                                                   disposition: "attachment"
    end

    def index
      return unless query_only!(:before, :limit)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = OpeningImport.all
      scope = scope.where("(opening_imports.created_at, opening_imports.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(uploaded_by_user: :professional).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: page.map { |import| summary(import) },
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    def create
      return file_too_large if request.content_length.to_i > MAX_BODY_BYTES || request.raw_post.bytesize > MAX_BODY_BYTES

      raw = body_param("file_base64")
      return render_refusal("file_base64", "invalid_file") unless raw.is_a?(String) && raw.present?
      return file_too_large if raw.bytesize > MAX_BASE64_BYTES

      bytes = decode(raw) or return render_refusal("file_base64", "invalid_file")
      result = OpeningImports::Upload.call(bytes: bytes, by: Current.user, usable_domains: usable_domains,
                                           required_domains: ::Bnafar::Gate.domains(Current.city))
      return render_failure(result) if result.failure?

      @import = result.payload.fetch(:import)
      render_import(status: :created)
    end

    def show
      return unless query_only!(:before, :limit, :status)

      render_import
    end

    def apply
      require_step_up!
      return if performed?

      act(OpeningImports::Apply, usable_domains: usable_domains, now: Time.current)
    end

    def revert
      require_step_up!
      return if performed?

      act(OpeningImports::Revert, now: Time.current)
    end

    def discard
      act(OpeningImports::Discard)
    end

    private

    def require_importer!
      forbid unless admin? || Access.central_keeper?(Current.user)
    end

    def load_import
      @import = uuid?(params[:id]) ? OpeningImport.find_by(id: params[:id]) : nil
      not_found unless @import
    end

    def act(command, **extra)
      result = command.call(import: @import, expected_version: body_param("expected_version"), by: Current.user, **extra)
      return render_failure(result) if result.failure?

      @import = result.payload.fetch(:import)
      render_import
    end

    def file_too_large = render(json: { error: "file_too_large", path: "file_base64" }, status: :payload_too_large)

    def decode(raw)
      Base64.strict_decode64(raw)
    rescue ArgumentError
      nil
    end

    # Domínios de estoque utilizáveis (R24), lidos fora da transação.
    def usable_domains = Stock::Domain::FEATURES.keys.select { |domain| stock_domain_usable?(domain) }

    def summary(import)
      { id: import.id, status: import.status, version: import.version, rows_total: import.rows_total, rows_valid: import.rows_valid,
        created_at: import.created_at.iso8601, applied_at: import.applied_at&.iso8601, reverted_at: import.reverted_at&.iso8601,
        uploaded_by: { name: import.uploaded_by_user.professional&.professional_name || NO_NAME } }
    end

    # <import>: o resumo, o relatório e uma página das linhas.
    def render_import(status: :ok)
      limit = page_limit or return
      filter = params[:status]
      return render_refusal("status") if filter.present? && !ROW_STATUSES.include?(filter)

      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      after = cursor&.size == 1 ? Integer(cursor.first, 10, exception: false) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && after.nil?

      scope = OpeningImportRow.where(opening_import_id: @import.id)
      scope = scope.where(status: filter) if filter.present?
      scope = scope.where("line > ?", after) if after
      rows = scope.order(:line).limit(limit + 1).to_a
      page = rows.first(limit)
      render status: status, json: summary(@import).merge(
        report: OpeningImports::Report.call(@import), rows: page.map { |row| row_json(row) },
        next_before: rows.size > limit ? Cursor.encode([ page.last.line ]) : nil
      )
    end

    def row_json(row)
      { line: row.line, status: row.status, error_codes: row.error_codes, stock_location_id: row.stock_location_id }
        .merge(ROW_COLUMNS.to_h { |column| [ column, row[column] ] })
    end
  end
end
