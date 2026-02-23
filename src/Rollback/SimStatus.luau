local types = require("./Types")

local status: types.map<string, string> = {
	--Only Simulating, Resimulating and Predicting are really used

	Syncing = "Syncing",
	Simulating = "Simulating",
	RollingBack = "RollingBack",
	Resimulating = "Resimulating",
	Predicting = "Predicting",
}

return status
