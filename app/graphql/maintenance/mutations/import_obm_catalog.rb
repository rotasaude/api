require "base64"

module Maintenance
  module Mutations
    # Módulo 27b (contrato Q12): carga do arquivo OBM — apresentações e o VMP dos
    # itens do catálogo. A API de manutenção inteira só é desenhada em
    # development, test e staging (config/routes.rb:46-52); em produção a carga
    # é a rake medications:import_obm, então o campo não precisa de condicional
    # no schema. Sessão humana (HumanOnly) e step-up de TOTP: o arquivo muda o
    # catálogo de todas as cidades. O corpo maior (GraphqlController::
    # UPLOAD_BODY_BYTES) vale só para esta operação. O arquivo nunca entra na
    # auditoria: só o número de linhas.
    class ImportObmCatalog < BaseMutation
      description "Carrega o arquivo OBM (CSV em Base64): apresentações e o VMP dos itens do catálogo. Exige o TOTP do momento."

      argument :file_base64, String, required: true, description: "O CSV do OBM em Base64"
      argument :code, String, required: true, description: "TOTP do momento"

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :added, Integer, null: true
      field :changed, Integer, null: true
      field :deactivated, Integer, null: true
      field :vmp_linked, Integer, null: true
      field :unmatched, Integer, null: true

      EMPTY = { added: nil, changed: nil, deactivated: nil, vmp_linked: nil, unmatched: nil }.freeze

      def resolve(file_base64:, code:)
        csv = decode(file_base64)
        outcome = nil
        result = audited(event: "maintenance.obm_catalog.imported", module_name: "medications", rows: rows_in(csv)) do
          step_up!(code)
          raise Rejected.new("invalid_file", path: "file") if csv.nil?

          outcome = Medications::ObmImport.call(csv: csv, by: "maintenance:#{credential.maintainer.id}")
          raise Rejected.new(outcome.reason.to_s, path: outcome.details[:path] || "file") if outcome.failure?
        end
        return result.merge(EMPTY) unless outcome&.ok?

        result.merge(outcome.payload.slice(*EMPTY.keys))
      end

      private

      def decode(file_base64)
        Base64.strict_decode64(file_base64)
      rescue ArgumentError
        nil
      end

      # Linhas de dados (sem o cabeçalho), para a auditoria.
      def rows_in(csv) = csv ? [ csv.each_line.count - 1, 0 ].max : 0
    end
  end
end
