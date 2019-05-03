{:ok, _} = Application.ensure_all_started(:ibrowse)
{:ok, _} = Application.ensure_all_started(:hackney)
ExUnit.start()
