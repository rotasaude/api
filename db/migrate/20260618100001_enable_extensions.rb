class EnableExtensions < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pgcrypto"   # gen_random_uuid()
    enable_extension "citext"     # case-insensitive text para enums string
  end
end
