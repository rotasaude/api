module Maintenance
  module Mutations
    # Módulo 25 (ADR 0043): publica a versão seguinte da lista nacional. Só
    # plataforma (não abre cidade). Step-up de TOTP: a lista decide o que toda
    # cidade notifica. Auditoria: tentativa/resultado pela base e
    # notifiable_disease_list.published pelo serviço, ambos só com ids e números (R18).
    class PublishNotifiableDiseaseList < BaseMutation
      description "Publica uma versão nova da lista nacional de doenças de notificação compulsória. Exige o TOTP do momento."

      argument :ordinance, String, required: true
      argument :effective_from, GraphQL::Types::ISO8601Date, required: true
      argument :diseases, [ Types::NotifiableDiseaseInput ], required: true
      argument :notes, String, required: false
      # Anulável no schema pelo mesmo motivo de revertProtocolActivation: a
      # ausência vira recusa com path expectedVersion, não erro de validação.
      argument :expected_version, Integer, required: false,
               description: "A versão vigente de onde o rascunho partiu (nula só para a primeira). " \
                            "Divergente, a publicação é recusada."
      argument :code, String, required: true, description: "TOTP do momento"

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false
      field :version, Integer, null: true

      def resolve(ordinance:, effective_from:, diseases:, code:, expected_version: nil, notes: nil)
        published = nil
        list = diseases.map { |d| d.to_h.deep_stringify_keys }

        result = audited(event: "maintenance.notifiable_disease_list.published", module_name: "surveillance",
                         diseases_count: list.size, expected_version: expected_version) do
          step_up!(code)
          raise Rejected.new("versão de partida ausente", path: "expectedVersion") if expected_version.nil?

          outcome = Surveillance::DiseaseList::Publish.call(ordinance: ordinance, effective_from: effective_from, diseases: list,
                                                            expected_version: expected_version, notes: notes,
                                                            maintainer: credential.maintainer)
          if outcome.failure?
            raise Rejected.new("a lista mudou desde a versão #{expected_version}", path: "expectedVersion") if outcome.reason == :stale_version

            raise Rejected.new(outcome.reason.to_s, path: client_path(outcome.details[:path]))
          end
          published = outcome.payload.fetch(:version).version
        end

        result.merge(version: published)
      end

      private

      # Os caminhos do serviço são do banco (repeat_after_days); o cliente fala
      # camelCase. Índices numéricos passam como estão.
      def client_path(path)
        path.to_s.split(".").map { |seg| seg.match?(/\A\d+\z/) ? seg : seg.camelize(:lower) }.join(".")
      end
    end
  end
end
