# Conduta LEDI da consulta (ADR 0031; Task 1). Adendo acrescenta ou remove
# (linha `remove`); o efetivo é Consultations::Effective. Só acréscimo.
class ConsultationConduct < ApplicationRecord
  ACTIONS = %w[add remove].freeze

  belongs_to :consultation
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
end
