# CurrentAttributes resetado por request e por job (ver ADR-0019, ADR-0020).
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :municipality_id

  delegate :user, to: :session, allow_nil: true
end
