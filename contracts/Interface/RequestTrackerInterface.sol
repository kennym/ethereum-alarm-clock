pragma solidity ^0.4.17;

contract RequestTrackerInterface {
    function getWindowStart(address factory, address request) view returns (uint);
    function getPreviousRequest(address factory, address request) view returns (address);
    function getNextRequest(address factory, address request) view returns (address);
    function addRequest(address request, uint startWindow) public returns (bool);
    function removeRequest(address request) public returns (bool);
    function isKnownRequest(address factory, address request) view returns (bool);
    function query(address factory, bytes2 operator, uint value) view returns (address);
}