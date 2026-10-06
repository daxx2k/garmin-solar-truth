// Release builds contain no embedded personal or demonstration readings.
(:glance)
module TodaySolarData {
    const DAY = "";
    const SOURCE_LABEL = "src: live";
    const SOURCE_DETAIL = "watch samples";
    const COUNT = 0;
    const RAW_SAMPLE_COUNT = 0;
    const T = [];
    const SI = [];
    function isForToday() { return false; }
    function toSamples() { return []; }
    function lastEpoch() { return null; }
}
