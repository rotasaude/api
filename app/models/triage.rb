# Estado da triage em curso de um cidadão. Manipulado APENAS via commands.
# Ver ADR-0004 (commands) e ADR-0009 (motor de protocolos).
class Triage < ApplicationRecord
  belongs_to :conversation
  belongs_to :protocol_definition
  has_one :report_snapshot
  has_one :attendance, dependent: :restrict_with_error

  enum :status, {
    in_progress: "in_progress",
    completed: "completed",
    aborted_by_revocation: "aborted_by_revocation",
    aborted_by_timeout: "aborted_by_timeout",
    aborted_by_cancellation: "aborted_by_cancellation"
  }, prefix: true

  validates :protocol_name, presence: true
  # answers é jsonb e começa vazio ({}) ao iniciar a triage. presence: true
  # falha em hash vazio (Rails considera blank). Disallow só nil.
  validates :answers, exclusion: { in: [nil] }

  def append_answer!(answer)
    self.answers = answers.merge(current_step.to_s => answer)
    self.current_step = next_step_id(answer)
    save!
  end

  def complete!(outcome)
    update!(
      status: :completed,
      tier: outcome.tier,
      priority: outcome.priority,
      completed_at: Time.current,
      outcome: outcome.to_h
    )
  end

  def protocol
    Protocols.fetch(
      name: protocol_name,
      version: protocol_definition.version
    )
  end

  def record_answer!(answer)
    protocol.evaluate(answers.merge(current_step.to_s => answer))
  end

  def next_prompt_template(outcome)
    return template(:completed, outcome: outcome) if outcome.terminal?
    template(:ask, step: outcome.awaiting)
  end

  private

  def template(kind, **vars)
    {
      name: "rota_saude_#{kind}",
      language: { code: "pt_BR" },
      components: vars.any? ? [{ type: "body", parameters: vars.map { |_, v| { type: "text", text: v.to_s } } }] : []
    }
  end

  def next_step_id(answer)
    protocol.steps[current_step.to_sym]&.next_step_id(answer)
  end
end
