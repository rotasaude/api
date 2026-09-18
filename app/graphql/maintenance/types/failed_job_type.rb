module Maintenance
  module Types
    class FailedJobType < BaseObject
      description "Execução falha do Solid Queue da cidade (o Solid Queue de cada cidade mora no banco dela). " \
                   "A MENSAGEM da exceção é texto não controlado que pode carregar dado de cidadão (um " \
                   "telefone, o corpo de uma mensagem, num erro de validação) — só a CLASSE da exceção sai, " \
                   "nunca a mensagem nem os argumentos do job."

      field :class_name, String, null: false
      field :failed_at, GraphQL::Types::ISO8601DateTime, null: false
      field :error_class, String, null: true

      def class_name = object.job.class_name
      def failed_at = object.created_at
      def error_class = object.error.present? ? object.exception_class : nil
    end
  end
end
