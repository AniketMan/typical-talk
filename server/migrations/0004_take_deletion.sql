-- A take its author deleted. The row stays (without its file) so other phones
-- learn about the deletion on their next sync and drop their copy.
ALTER TABLE takes ADD COLUMN deleted_at INTEGER;
