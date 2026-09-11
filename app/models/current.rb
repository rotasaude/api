# CurrentAttributes resetado por request e por job (ver ADR-0003).
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :municipality_id

  delegate :user, to: :session, allow_nil: true
end
