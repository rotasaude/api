require "rails_helper"

# F-06.13: o termo de consentimento é append-only (ADR-0013). O consentimento
# do cidadão aponta para a versão e o hash do texto — mudar ou apagar um termo
# publicado reescreveria o que ele aceitou. Versão nova é linha nova.
RSpec.describe "consent_terms append-only" do
  def attempt
    ConsentTerm.transaction(requires_new: true) { yield }
  end

  let!(:term) { ConsentTerm.create!(version: "71", body: "termo v71", published_at: Time.current) }

  it "recusa UPDATE, mesmo por update_column e update_all" do
    expect { attempt { term.update_column(:body, "outro texto") } }
      .to raise_error(ActiveRecord::StatementInvalid, /consent_terms is append-only: UPDATE refused/)
    expect { attempt { ConsentTerm.where(id: term.id).update_all(version: "72") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(term.reload.body).to eq("termo v71")
  end

  it "recusa DELETE, mesmo por delete_all" do
    expect { attempt { ConsentTerm.where(id: term.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /consent_terms is append-only: DELETE refused/)
    expect(ConsentTerm.exists?(term.id)).to be(true)
  end

  it "continua aceitando INSERT de versão nova" do
    expect { ConsentTerm.create!(version: "72", body: "termo v72", published_at: Time.current) }
      .to change(ConsentTerm, :count).by(1)
  end
end
