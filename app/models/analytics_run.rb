# Uma consolidação (ADR 0025; spec 2026-09-30 §3.2): a trilha do Analytics.
# `error` é classe + primeira linha da mensagem, nunca payload.
class AnalyticsRun < ApplicationRecord
  KINDS = %w[scheduled rebuild].freeze
  STATUSES = %w[running succeeded failed].freeze
end
